-- Pure-PL/pgSQL cryptographic primitives for IN-DATABASE wallet custody & signing.
--
-- WHY: hosted Supabase ships no secp256k1/keccak extension and forbids installing
-- custom C extensions, so EVM/Tron key derivation + transaction signing must be done
-- in pure SQL to keep the "the database IS the exchange" model on the hosted demo.
-- These use only pgcrypto (HMAC/SHA-256, in schema `extensions`) + numeric/bit math.
--
-- VALIDATED against ethers/js-sha3 as oracle: keccak256 matches for all input lengths
-- 0..300 (incl. rate-boundary 135/136/137/271/272/273); secp256k1 pubkeys + RFC6979
-- (r,s,v) match ethers exactly across 30 random (priv,z) pairs; anchor addresses
-- 0x7e5f4552…395bdf (priv=1) and 0x2b5ad5c4…ccd6cf (priv=2) confirmed.
--
-- PERF: a sign / scalar-mult is tens–hundreds of ms in plpgsql — fine for low-rate
-- withdrawals. TESTNET ONLY: a master seed lives in the DB (vault), so DB access ==
-- fund control. Never custody real funds with this.
--
-- These are INTERNAL primitives: only SECURITY DEFINER wrappers (HD derivation,
-- withdrawal signer) and service_role should call them — revoked from anon/authenticated
-- at the end. Numbered >9900 so 9900_lockdown's revoke loop has already run.

-- ============================================================ keccak256 (Ethereum)
CREATE OR REPLACE FUNCTION public.keccak256(input bytea)
RETURNS bytea
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  st     bit(64)[];
  bb     bit(64)[];
  cc     bit(64)[];
  dd     bit(64)[];
  rho    int[] := ARRAY[
            0, 1,62,28,27,
           36,44, 6,55,20,
            3,10,43,25,39,
           41,45,15,21, 8,
           18, 2,61,56,14];
  rc     bit(64)[] := ARRAY[
           x'0000000000000001'::bit(64), x'0000000000008082'::bit(64),
           x'800000000000808A'::bit(64), x'8000000080008000'::bit(64),
           x'000000000000808B'::bit(64), x'0000000080000001'::bit(64),
           x'8000000080008081'::bit(64), x'8000000000008009'::bit(64),
           x'000000000000008A'::bit(64), x'0000000000000088'::bit(64),
           x'0000000080008009'::bit(64), x'000000008000000A'::bit(64),
           x'000000008000808B'::bit(64), x'800000000000008B'::bit(64),
           x'8000000000008089'::bit(64), x'8000000000008003'::bit(64),
           x'8000000000008002'::bit(64), x'8000000000000080'::bit(64),
           x'000000000000800A'::bit(64), x'800000008000000A'::bit(64),
           x'8000000080008081'::bit(64), x'8000000000008080'::bit(64),
           x'0000000080000001'::bit(64), x'8000000080008008'::bit(64)];
  zero64 bit(64) := x'0000000000000000'::bit(64);
  msg    bytea;
  mlen   int;
  rate   int := 136;
  nblocks int;
  padlen int;
  blk    int;
  i      int;
  x      int;
  y      int;
  idx    int;
  rnd    int;
  rot    int;
  lane   bit(64);
  bytepos int;
  out    bytea;
BEGIN
  mlen := coalesce(octet_length(input), 0);
  nblocks := (mlen / rate) + 1;
  padlen := nblocks * rate - mlen;
  msg := input || decode(repeat('00', padlen), 'hex');
  msg := set_byte(msg, mlen, get_byte(msg, mlen) | 1);
  msg := set_byte(msg, mlen + padlen - 1, get_byte(msg, mlen + padlen - 1) | 128);

  st := array_fill(zero64, ARRAY[25]);

  FOR blk IN 0 .. nblocks - 1 LOOP
    FOR i IN 0 .. 16 LOOP
      bytepos := blk * rate + i * 8;
      lane :=  (get_byte(msg, bytepos + 7)::bit(64) << 56)
             | (get_byte(msg, bytepos + 6)::bit(64) << 48)
             | (get_byte(msg, bytepos + 5)::bit(64) << 40)
             | (get_byte(msg, bytepos + 4)::bit(64) << 32)
             | (get_byte(msg, bytepos + 3)::bit(64) << 24)
             | (get_byte(msg, bytepos + 2)::bit(64) << 16)
             | (get_byte(msg, bytepos + 1)::bit(64) << 8)
             | (get_byte(msg, bytepos + 0)::bit(64));
      st[i + 1] := st[i + 1] # lane;
    END LOOP;

    FOR rnd IN 0 .. 23 LOOP
      cc := ARRAY[]::bit(64)[];
      FOR x IN 0 .. 4 LOOP
        cc[x + 1] := st[x + 1] # st[x + 6] # st[x + 11] # st[x + 16] # st[x + 21];
      END LOOP;
      dd := ARRAY[]::bit(64)[];
      FOR x IN 0 .. 4 LOOP
        lane := cc[((x + 1) % 5) + 1];
        dd[x + 1] := cc[((x + 4) % 5) + 1] # ((lane << 1) | (lane >> 63));
      END LOOP;
      FOR y IN 0 .. 4 LOOP
        FOR x IN 0 .. 4 LOOP
          st[x + 5 * y + 1] := st[x + 5 * y + 1] # dd[x + 1];
        END LOOP;
      END LOOP;

      bb := array_fill(zero64, ARRAY[25]);
      FOR y IN 0 .. 4 LOOP
        FOR x IN 0 .. 4 LOOP
          idx := x + 5 * y;
          rot := rho[idx + 1];
          lane := st[idx + 1];
          IF rot = 0 THEN
            bb[y + 5 * ((2 * x + 3 * y) % 5) + 1] := lane;
          ELSE
            bb[y + 5 * ((2 * x + 3 * y) % 5) + 1] := (lane << rot) | (lane >> (64 - rot));
          END IF;
        END LOOP;
      END LOOP;

      FOR y IN 0 .. 4 LOOP
        FOR x IN 0 .. 4 LOOP
          st[x + 5 * y + 1] :=
            bb[x + 5 * y + 1]
            # ((~ bb[((x + 1) % 5) + 5 * y + 1]) & bb[((x + 2) % 5) + 5 * y + 1]);
        END LOOP;
      END LOOP;

      st[1] := st[1] # rc[rnd + 1];
    END LOOP;
  END LOOP;

  out := '\x'::bytea;
  FOR i IN 0 .. 3 LOOP
    lane := st[i + 1];
    out := out
      || set_byte(set_byte(set_byte(set_byte(set_byte(set_byte(set_byte(set_byte(
           '\x0000000000000000'::bytea,
           0, substring(lane from 57 for 8)::int),
           1, substring(lane from 49 for 8)::int),
           2, substring(lane from 41 for 8)::int),
           3, substring(lane from 33 for 8)::int),
           4, substring(lane from 25 for 8)::int),
           5, substring(lane from 17 for 8)::int),
           6, substring(lane from  9 for 8)::int),
           7, substring(lane from  1 for 8)::int);
  END LOOP;

  RETURN out;
END;
$$;

CREATE OR REPLACE FUNCTION public.keccak256_hex(input bytea)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(public.keccak256(input), 'hex');
$$;

-- ============================================================ secp256k1 + ECDSA
CREATE OR REPLACE FUNCTION public.secp_powmod(base numeric, exp numeric, m numeric)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  r numeric := 1;
  b numeric := mod(base, m);
  e numeric := exp;
BEGIN
  IF b < 0 THEN b := b + m; END IF;
  WHILE e > 0 LOOP
    IF mod(e, 2) = 1 THEN
      r := mod(r * b, m);
    END IF;
    e := div(e, 2);
    b := mod(b * b, m);
  END LOOP;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_b2n(b bytea)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  r numeric := 0;
  i int;
BEGIN
  FOR i IN 0 .. length(b) - 1 LOOP
    r := r * 256 + get_byte(b, i);
  END LOOP;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_n2hex(x numeric)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  digits constant text := '0123456789abcdef';
  s text := '';
  v numeric := x;
  d int;
BEGIN
  WHILE v > 0 LOOP
    d := mod(v, 16)::int;
    s := substr(digits, d + 1, 1) || s;
    v := div(v, 16);
  END LOOP;
  RETURN lpad(s, 64, '0');
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_n2bytea(x numeric)
RETURNS bytea LANGUAGE sql IMMUTABLE AS $$
  SELECT decode(public.secp_n2hex(x), 'hex');
$$;

CREATE OR REPLACE FUNCTION public.secp_jdouble(jp numeric[])
RETURNS numeric[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  p constant numeric := 115792089237316195423570985008687907853269984665640564039457584007908834671663;
  X numeric := jp[1]; Y numeric := jp[2]; Z numeric := jp[3];
  XX numeric; YY numeric; YYYY numeric; ZZ numeric;
  S numeric; M numeric; T numeric; X3 numeric; Y3 numeric; Z3 numeric;
BEGIN
  IF Z = 0 OR Y = 0 THEN
    RETURN ARRAY[1::numeric, 1::numeric, 0::numeric];
  END IF;
  XX   := mod(X * X, p);
  YY   := mod(Y * Y, p);
  YYYY := mod(YY * YY, p);
  ZZ   := mod(Z * Z, p);
  S    := mod(2 * (mod((X + YY) * (X + YY), p) - XX - YYYY), p);
  M    := mod(3 * XX, p);
  T    := mod(M * M - 2 * S, p);
  X3   := T;
  Y3   := mod(M * (S - T) - 8 * YYYY, p);
  Z3   := mod(mod((Y + Z) * (Y + Z), p) - YY - ZZ, p);
  RETURN ARRAY[mod(X3 + p, p), mod(Y3 + p, p), mod(Z3 + p, p)];
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_jadd(jp numeric[], jq numeric[])
RETURNS numeric[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  p constant numeric := 115792089237316195423570985008687907853269984665640564039457584007908834671663;
  X1 numeric := jp[1]; Y1 numeric := jp[2]; Z1 numeric := jp[3];
  X2 numeric := jq[1]; Y2 numeric := jq[2]; Z2 numeric := jq[3];
  Z1Z1 numeric; Z2Z2 numeric; U1 numeric; U2 numeric; S1 numeric; S2 numeric;
  H numeric; ii numeric; jj numeric; r numeric; V numeric;
  X3 numeric; Y3 numeric; Z3 numeric;
BEGIN
  IF Z1 = 0 THEN RETURN jq; END IF;
  IF Z2 = 0 THEN RETURN jp; END IF;
  Z1Z1 := mod(Z1 * Z1, p);
  Z2Z2 := mod(Z2 * Z2, p);
  U1 := mod(X1 * Z2Z2, p);
  U2 := mod(X2 * Z1Z1, p);
  S1 := mod(mod(Y1 * Z2, p) * Z2Z2, p);
  S2 := mod(mod(Y2 * Z1, p) * Z1Z1, p);
  H  := mod(U2 - U1 + p, p);
  r  := mod(2 * (S2 - S1) + 2 * p, p);
  IF H = 0 THEN
    IF r = 0 THEN
      RETURN public.secp_jdouble(jp);
    ELSE
      RETURN ARRAY[1::numeric, 1::numeric, 0::numeric];
    END IF;
  END IF;
  ii := mod((2 * H) * (2 * H), p);
  jj := mod(H * ii, p);
  V  := mod(U1 * ii, p);
  X3 := mod(r * r - jj - 2 * V + 2 * p, p);
  Y3 := mod(r * (V - X3) - 2 * mod(S1 * jj, p) + 2 * p, p);
  Z3 := mod(mod((mod((Z1 + Z2) * (Z1 + Z2), p) - Z1Z1 - Z2Z2 + 2 * p), p) * H, p);
  RETURN ARRAY[mod(X3 + p, p), mod(Y3 + p, p), mod(Z3 + p, p)];
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_mul(scalar numeric, px numeric, py numeric)
RETURNS numeric[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  p constant numeric := 115792089237316195423570985008687907853269984665640564039457584007908834671663;
  acc numeric[] := ARRAY[1::numeric, 1::numeric, 0::numeric];
  base numeric[] := ARRAY[px, py, 1::numeric];
  bits int[] := ARRAY[]::int[];
  k numeric := scalar;
  i int;
  zinv numeric; zinv2 numeric;
BEGIN
  IF scalar = 0 THEN RETURN NULL; END IF;
  WHILE k > 0 LOOP
    bits := array_append(bits, mod(k, 2)::int);
    k := div(k, 2);
  END LOOP;
  FOR i IN REVERSE array_length(bits, 1) .. 1 LOOP
    acc := public.secp_jdouble(acc);
    IF bits[i] = 1 THEN
      acc := public.secp_jadd(acc, base);
    END IF;
  END LOOP;
  IF acc[3] = 0 THEN RETURN NULL; END IF;
  zinv  := public.secp_powmod(acc[3], p - 2, p);
  zinv2 := mod(zinv * zinv, p);
  RETURN ARRAY[ mod(acc[1] * zinv2, p),
                mod(mod(acc[2] * zinv2, p) * zinv, p) ];
END;
$$;

-- 64-byte uncompressed pubkey X(32)||Y(32), no 0x04 prefix
CREATE OR REPLACE FUNCTION public.secp_pubkey(priv bytea)
RETURNS bytea LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  Gx constant numeric := 55066263022277343669578718895168534326250603453777594175500187360389116729240;
  Gy constant numeric := 32670510020758816978083085130507043184471273380659243275938904335757337482424;
  d numeric := public.secp_b2n(priv);
  pt numeric[];
BEGIN
  pt := public.secp_mul(d, Gx, Gy);
  IF pt IS NULL THEN
    RAISE EXCEPTION 'invalid private key (results in point at infinity)';
  END IF;
  RETURN decode(public.secp_n2hex(pt[1]) || public.secp_n2hex(pt[2]), 'hex');
END;
$$;

-- RFC6979 deterministic ECDSA over 32-byte hash z; low-s normalized.
-- returns {"r":hex,"s":hex,"v":0|1}
CREATE OR REPLACE FUNCTION public.secp_sign(priv bytea, z bytea)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  n  constant numeric := 115792089237316195423570985008687907852837564279074904382605163141518161494337;
  Gx constant numeric := 55066263022277343669578718895168534326250603453777594175500187360389116729240;
  Gy constant numeric := 32670510020758816978083085130507043184471273380659243275938904335757337482424;
  half constant numeric := 57896044618658097711785492504343953926418782139537452191302581570759080747168;
  d numeric := public.secp_b2n(priv);
  zint numeric := public.secp_b2n(z);
  priv_oct bytea := public.secp_n2bytea(d);
  z_oct bytea := public.secp_n2bytea(mod(zint, n));
  vv bytea := decode(repeat('01', 32), 'hex');
  kk bytea := decode(repeat('00', 32), 'hex');
  tt bytea;
  knonce numeric;
  pt numeric[];
  sig_r numeric;
  sig_s numeric;
  parity int;
BEGIN
  kk := extensions.hmac(vv || '\x00'::bytea || priv_oct || z_oct, kk, 'sha256');
  vv := extensions.hmac(vv, kk, 'sha256');
  kk := extensions.hmac(vv || '\x01'::bytea || priv_oct || z_oct, kk, 'sha256');
  vv := extensions.hmac(vv, kk, 'sha256');

  LOOP
    vv := extensions.hmac(vv, kk, 'sha256');
    tt := vv;
    knonce := public.secp_b2n(tt);
    IF knonce >= 1 AND knonce < n THEN
      pt := public.secp_mul(knonce, Gx, Gy);
      IF pt IS NOT NULL THEN
        sig_r := mod(pt[1], n);
        IF sig_r <> 0 THEN
          sig_s := mod( public.secp_powmod(knonce, n - 2, n)
                    * mod(zint + mod(sig_r * d, n), n), n );
          IF sig_s <> 0 THEN
            parity := mod(pt[2], 2)::int;
            IF sig_s > half THEN
              sig_s := n - sig_s;
              parity := 1 - parity;
            END IF;
            RETURN jsonb_build_object(
              'r', public.secp_n2hex(sig_r),
              's', public.secp_n2hex(sig_s),
              'v', parity);
          END IF;
        END IF;
      END IF;
    END IF;
    kk := extensions.hmac(vv || '\x00'::bytea, kk, 'sha256');
    vv := extensions.hmac(vv, kk, 'sha256');
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_verify(pub bytea, z bytea, r bytea, s bytea)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  n  constant numeric := 115792089237316195423570985008687907852837564279074904382605163141518161494337;
  Gx constant numeric := 55066263022277343669578718895168534326250603453777594175500187360389116729240;
  Gy constant numeric := 32670510020758816978083085130507043184471273380659243275938904335757337482424;
  Qx numeric := public.secp_b2n(substr(pub, 1, 32));
  Qy numeric := public.secp_b2n(substr(pub, 33, 32));
  rn numeric := public.secp_b2n(r);
  sn numeric := public.secp_b2n(s);
  zint numeric := public.secp_b2n(z);
  w numeric; u1 numeric; u2 numeric;
  P1 numeric[]; P2 numeric[];
  J1 numeric[]; J2 numeric[]; J numeric[];
BEGIN
  IF rn < 1 OR rn >= n OR sn < 1 OR sn >= n THEN
    RETURN false;
  END IF;
  w  := public.secp_powmod(sn, n - 2, n);
  u1 := mod(zint * w, n);
  u2 := mod(rn * w, n);

  P1 := public.secp_mul(u1, Gx, Gy);
  P2 := public.secp_mul(u2, Qx, Qy);

  IF P1 IS NULL THEN J1 := ARRAY[1::numeric,1::numeric,0::numeric];
  ELSE J1 := ARRAY[P1[1], P1[2], 1::numeric]; END IF;
  IF P2 IS NULL THEN J2 := ARRAY[1::numeric,1::numeric,0::numeric];
  ELSE J2 := ARRAY[P2[1], P2[2], 1::numeric]; END IF;

  J := public.secp_jadd(J1, J2);
  IF J[3] = 0 THEN
    RETURN false;
  END IF;
  DECLARE
    p constant numeric := 115792089237316195423570985008687907853269984665640564039457584007908834671663;
    zinv numeric := public.secp_powmod(J[3], p - 2, p);
    xaff numeric;
  BEGIN
    xaff := mod(J[1] * mod(zinv * zinv, p), p);
    RETURN mod(xaff, n) = rn;
  END;
END;
$$;

-- ---------- EVM address = last 20 bytes of keccak256(uncompressed pubkey) ----------
CREATE OR REPLACE FUNCTION public.evm_address(priv bytea)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT '0x' || encode(substr(public.keccak256(public.secp_pubkey(priv)), 13, 20), 'hex');
$$;

-- internal primitives: callable only by SECURITY DEFINER wrappers + service_role
REVOKE EXECUTE ON FUNCTION
  public.keccak256(bytea), public.keccak256_hex(bytea),
  public.secp_powmod(numeric,numeric,numeric), public.secp_b2n(bytea),
  public.secp_n2hex(numeric), public.secp_n2bytea(numeric),
  public.secp_jdouble(numeric[]), public.secp_jadd(numeric[],numeric[]),
  public.secp_mul(numeric,numeric,numeric), public.secp_pubkey(bytea),
  public.secp_sign(bytea,bytea), public.secp_verify(bytea,bytea,bytea,bytea),
  public.evm_address(bytea)
FROM public, anon, authenticated;
