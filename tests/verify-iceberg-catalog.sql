SELECT EXISTS (
  SELECT 1
  FROM public."DBS" AS d
  JOIN public."TBLS" AS t ON t."DB_ID" = d."DB_ID"
  WHERE d."NAME" = 'spark_iceberg_smoke'
    AND t."TBL_NAME" = 'smoke_table'
);
