--
-- kernel_nbody: examples/kernels/nbody.ll (from src/nbody.c) against the
-- PL/pgSQL original (bench/kernels/10_nbody.sql, nbody_imm)
--
SET plllvm.regress_test_mode = on;

\getenv abs_srcdir PG_ABS_SRCDIR
\set ir `cat :'abs_srcdir'/examples/kernels/nbody.ll`

CREATE FUNCTION nbody_ll(n integer) RETURNS text
LANGUAGE plllvm IMMUTABLE AS :'ir';

CREATE FUNCTION nbody_pl(n integer) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  pi CONSTANT float8 := 3.141592653589793;
  solar_mass float8;
  days_per_year CONSTANT float8 := 365.24;
  dt CONSTANT float8 := 0.01;
  half CONSTANT float8 := 0.5;
  zero CONSTANT float8 := 0.0;
  nb CONSTANT integer := 5;
  x float8[]; y float8[]; z float8[];
  vx float8[]; vy float8[]; vz float8[];
  m float8[];
  i integer; j integer; s integer;
  dx float8; dy float8; dz float8; d2 float8; mag float8; mi float8; mj float8;
  px float8 := 0; py float8 := 0; pz float8 := 0;
  e float8;
  e0 float8;
BEGIN
  solar_mass := 4 * pi * pi;
  --          sun   jupiter                 saturn                  uranus                  neptune
  x  := ARRAY[zero, 4.84143144246472090e+00, 8.34336671824457987e+00, 1.28943695621391310e+01, 1.53796971148509165e+01]::float8[];
  y  := ARRAY[zero, -1.16032004402742839e+00, 4.12479856412430479e+00, -1.51111514016986312e+01, -2.59193146099879641e+01]::float8[];
  z  := ARRAY[zero, -1.03622044471123109e-01, -4.03523417114321381e-01, -2.23307578892655734e-01, 1.79258772950371181e-01]::float8[];
  vx := ARRAY[zero, 1.66007664274403694e-03 * days_per_year, -2.76742510726862411e-03 * days_per_year,
              2.96460137564761618e-03 * days_per_year, 2.68067772490389322e-03 * days_per_year]::float8[];
  vy := ARRAY[zero, 7.69901118419740425e-03 * days_per_year, 4.99852801234917238e-03 * days_per_year,
              2.37847173959480950e-03 * days_per_year, 1.62824170038242295e-03 * days_per_year]::float8[];
  vz := ARRAY[zero, -6.90460016972063023e-05 * days_per_year, 2.30417297573763929e-05 * days_per_year,
              -2.96589568540237556e-05 * days_per_year, -9.51592254519715870e-05 * days_per_year]::float8[];
  m  := ARRAY[solar_mass, 9.54791938424326609e-04 * solar_mass, 2.85885980666130812e-04 * solar_mass,
              4.36624404335156298e-05 * solar_mass, 5.15138902046611451e-05 * solar_mass]::float8[];

  -- offset momentum
  FOR i IN 1..nb LOOP
    px := px + vx[i] * m[i];
    py := py + vy[i] * m[i];
    pz := pz + vz[i] * m[i];
  END LOOP;
  vx[1] := - px / solar_mass;
  vy[1] := - py / solar_mass;
  vz[1] := - pz / solar_mass;

  -- energy (before)
  e := zero;
  FOR i IN 1..nb LOOP
    e := e + half * m[i] * (vx[i]*vx[i] + vy[i]*vy[i] + vz[i]*vz[i]);
    FOR j IN i+1..nb LOOP
      dx := x[i] - x[j]; dy := y[i] - y[j]; dz := z[i] - z[j];
      e := e - (m[i] * m[j]) / sqrt(dx*dx + dy*dy + dz*dz);
    END LOOP;
  END LOOP;
  e0 := e;

  -- advance n steps
  FOR s IN 1..n LOOP
    FOR i IN 1..nb LOOP
      FOR j IN i+1..nb LOOP
        dx := x[i] - x[j];
        dy := y[i] - y[j];
        dz := z[i] - z[j];
        d2 := dx*dx + dy*dy + dz*dz;
        mag := dt / (d2 * sqrt(d2));
        mi := m[i] * mag;
        mj := m[j] * mag;
        vx[i] := vx[i] - dx * mj;
        vy[i] := vy[i] - dy * mj;
        vz[i] := vz[i] - dz * mj;
        vx[j] := vx[j] + dx * mi;
        vy[j] := vy[j] + dy * mi;
        vz[j] := vz[j] + dz * mi;
      END LOOP;
    END LOOP;
    FOR i IN 1..nb LOOP
      x[i] := x[i] + dt * vx[i];
      y[i] := y[i] + dt * vy[i];
      z[i] := z[i] + dt * vz[i];
    END LOOP;
  END LOOP;

  -- energy (after)
  e := zero;
  FOR i IN 1..nb LOOP
    e := e + half * m[i] * (vx[i]*vx[i] + vy[i]*vy[i] + vz[i]*vz[i]);
    FOR j IN i+1..nb LOOP
      dx := x[i] - x[j]; dy := y[i] - y[j]; dz := z[i] - z[j];
      e := e - (m[i] * m[j]) / sqrt(dx*dx + dy*dy + dz*dz);
    END LOOP;
  END LOOP;

  RETURN round(e0::numeric, 9)::text || ' ' || round(e::numeric, 9)::text;
END
$$;

CREATE FUNCTION sqlstate_of(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE q;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END
$$;

SELECT s.n, nbody_ll(s.n) AS ll, nbody_ll(s.n) = nbody_pl(s.n) AS ok
FROM (SELECT n FROM (VALUES (0), (1), (10), (1000)) v(n) OFFSET 0) s
ORDER BY s.n;

SELECT sqlstate_of('SELECT nbody_ll(n) FROM (SELECT NULL::int AS n OFFSET 0) s') AS ll,
       sqlstate_of('SELECT nbody_pl(n) FROM (SELECT NULL::int AS n OFFSET 0) s') AS pl;

-- the size of EXP-001
SELECT nbody_ll(85000);

SELECT frame FROM plllvm_code_cache()
 WHERE owner_oid = 'nbody_ll(integer)'::regprocedure;

DROP FUNCTION sqlstate_of(text);
DROP FUNCTION nbody_ll(integer);
DROP FUNCTION nbody_pl(integer);
