SET columnar.compression TO 'none';

SELECT count(distinct storageid) AS columnar_table_count FROM columnar.columnar_stripes \gset

CREATE TABLE t(a int, b int) USING columnar;

CREATE VIEW t_stripes AS
SELECT * FROM columnar.columnar_stripes a, pg_class b
WHERE a.storageid = columnar_relation_storageid(b.oid) AND b.relname='t';

SELECT count(*) FROM t_stripes;

INSERT INTO t SELECT i, i * i FROM generate_series(1, 10) i;
INSERT INTO t SELECT i, i * i FROM generate_series(11, 20) i;
INSERT INTO t SELECT i, i * i FROM generate_series(21, 30) i;

SELECT sum(a), sum(b) FROM t;
SELECT count(*) FROM t_stripes;

-- vacuum full should merge stripes together
VACUUM FULL t;

SELECT sum(a), sum(b) FROM t;
SELECT count(*) FROM t_stripes;

-- test the case when all data cannot fit into a single stripe
SELECT alter_columnar_table_set('t', stripe_row_count => 1000);
INSERT INTO t SELECT i, 2 * i FROM generate_series(1,2500) i;

SELECT sum(a), sum(b) FROM t;
SELECT count(*) FROM t_stripes;

VACUUM FULL t;

SELECT sum(a), sum(b) FROM t;
SELECT count(*) FROM t_stripes;

-- VACUUM FULL doesn't reclaim dropped columns, but converts them to NULLs
ALTER TABLE t DROP COLUMN a;

SELECT stripe, attr, chunk, minimum_value IS NULL, maximum_value IS NULL
FROM columnar.columnar_skipnodes a, pg_class b
WHERE a.storageid = columnar_relation_storageid(b.oid) AND b.relname='t' ORDER BY 1, 2, 3;

VACUUM FULL t;

SELECT stripe, attr, chunk, minimum_value IS NULL, maximum_value IS NULL
FROM columnar.columnar_skipnodes a, pg_class b
WHERE a.storageid = columnar_relation_storageid(b.oid) AND b.relname='t' ORDER BY 1, 2, 3;

-- Make sure we cleaned-up the transient table metadata after VACUUM FULL commands
SELECT count(distinct storageid) - :columnar_table_count FROM columnar.columnar_stripes;

-- do this in a transaction so concurrent autovacuum doesn't interfere with results
BEGIN;
SAVEPOINT s1;
SELECT count(*) FROM t;
SELECT pg_size_pretty(pg_relation_size('t'));
INSERT INTO t SELECT i FROM generate_series(1, 10000) i;
SELECT pg_size_pretty(pg_relation_size('t'));
SELECT count(*) FROM t;
ROLLBACK TO SAVEPOINT s1;

-- not truncated by VACUUM or autovacuum yet (being in transaction ensures this),
-- so relation size should be same as before.
SELECT pg_size_pretty(pg_relation_size('t'));
COMMIT;

-- vacuum should truncate the relation to the usable space
VACUUM VERBOSE t;
SELECT pg_size_pretty(pg_relation_size('t'));
SELECT count(*) FROM t;

-- add some stripes with different compression types and create some gaps,
-- then vacuum to print stats

BEGIN;
SELECT alter_columnar_table_set('t',
    chunk_row_count => 1000,
    stripe_row_count => 2000,
    compression => 'pglz');
SAVEPOINT s1;
INSERT INTO t SELECT i FROM generate_series(1, 1500) i;
ROLLBACK TO SAVEPOINT s1;
INSERT INTO t SELECT i / 5 FROM generate_series(1, 1500) i;
SELECT alter_columnar_table_set('t', compression => 'none');
SAVEPOINT s2;
INSERT INTO t SELECT i FROM generate_series(1, 1500) i;
ROLLBACK TO SAVEPOINT s2;
INSERT INTO t SELECT i / 5 FROM generate_series(1, 1500) i;
COMMIT;

VACUUM VERBOSE t;

SELECT count(*) FROM t;

-- check that we report chunks with data for dropped columns
ALTER TABLE t ADD COLUMN c int;
INSERT INTO t SELECT 1, i / 5 FROM generate_series(1, 1500) i;
ALTER TABLE t DROP COLUMN c;

VACUUM VERBOSE t;

-- vacuum full should remove chunks for dropped columns
-- note that, a chunk will be stored in non-compressed for if compression
-- doesn't reduce its size.
SELECT alter_columnar_table_set('t', compression => 'pglz');
VACUUM FULL t;
VACUUM VERBOSE t;

DROP TABLE t;
DROP VIEW t_stripes;

-- Make sure we cleaned the metadata for t too
SELECT count(distinct storageid) - :columnar_table_count FROM columnar.columnar_stripes;

-- A table with high compression ratio
SET columnar.compression TO 'pglz';
SET columnar.stripe_row_count TO 1000000;
SET columnar.chunk_row_count TO 100000;
CREATE TABLE t(a int, b char, c text) USING columnar;
INSERT INTO t SELECT 1, 'a', 'xyz' FROM generate_series(1, 1000000) i;

VACUUM VERBOSE t;

DROP TABLE t;
