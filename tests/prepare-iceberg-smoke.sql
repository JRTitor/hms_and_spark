DROP TABLE IF EXISTS iceberg.spark_iceberg_smoke.smoke_table;
DROP NAMESPACE IF EXISTS iceberg.spark_iceberg_smoke CASCADE;
CREATE NAMESPACE iceberg.spark_iceberg_smoke;

CREATE TABLE iceberg.spark_iceberg_smoke.smoke_table (
  id INT,
  message STRING
) USING iceberg;

INSERT INTO iceberg.spark_iceberg_smoke.smoke_table VALUES
  (1, 'first'),
  (2, 'second');

SELECT assert_true(
  COUNT(*) = 2
  AND SUM(CASE WHEN id = 1 AND message = 'first' THEN 1 ELSE 0 END) = 1
  AND SUM(CASE WHEN id = 2 AND message = 'second' THEN 1 ELSE 0 END) = 1
) AS prepared_rows_are_correct
FROM iceberg.spark_iceberg_smoke.smoke_table;

SELECT 'SPARK_ICEBERG_PREPARE_OK' AS test_result;
