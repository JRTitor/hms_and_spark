SHOW TABLES IN iceberg.spark_iceberg_smoke;

SELECT assert_true(
  COUNT(*) = 2
  AND SUM(CASE WHEN id = 1 AND message = 'first' THEN 1 ELSE 0 END) = 1
  AND SUM(CASE WHEN id = 2 AND message = 'second' THEN 1 ELSE 0 END) = 1
) AS rows_survived_new_session
FROM iceberg.spark_iceberg_smoke.smoke_table;

SELECT input_file_name() AS s3_data_file
FROM iceberg.spark_iceberg_smoke.smoke_table
LIMIT 1;

SELECT 'SPARK_ICEBERG_VERIFY_OK' AS test_result;
