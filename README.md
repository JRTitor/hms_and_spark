# Spark + Hive Metastore + Iceberg + PostgreSQL + S3

This stack runs Spark 4.0.1, Hive Metastore 4.0.0, PostgreSQL 17, and SeaweedFS 4.50. Hive 4.0.0 keeps the legacy metastore Thrift calls needed by Spark's bundled Hive client and Iceberg's HiveCatalog. Hive 4.0.1 removed those calls, so Iceberg table operations fail against it. Iceberg table metadata is registered in Hive Metastore/PostgreSQL; Iceberg metadata and data files are stored in the `warehouse` S3 bucket. There is no HDFS cluster.

Spark and Hive are configured with startup arguments. The containers do not mount `hive-site.xml` or `core-site.xml`.

## Start and test locally

From PowerShell in this directory:

```powershell
docker compose up -d --build --wait
docker compose ps
```

Wait for `postgres`, `seaweedfs`, `metastore`, and `spark` to report healthy. On first start, Spark downloads the Iceberg runtime, Hive 4.0.0 client jars, and the Hadoop S3A connector from Maven Central. Compose creates a separate `iceberg_metastore` database on first PostgreSQL initialization, preserving the existing `metastore` database and its schema.

Run the end-to-end smoke test:

```powershell
.\tests\run-smoke-test.ps1
```

It creates an Iceberg table through Spark Thrift Server, checks its Hive Metastore record in PostgreSQL, opens a new Spark SQL session to read the rows, and confirms the data file path is in S3. It leaves `iceberg.spark_iceberg_smoke.smoke_table` available for inspection. Remove it with:

```powershell
docker compose exec -T spark /opt/spark/bin/beeline -u 'jdbc:hive2://localhost:10000/default' -n local -f /tests/cleanup-iceberg-smoke.sql
```

## Query the Iceberg table

Connect Beeline or DBeaver to Spark Thrift Server at `localhost:10000`. The JDBC URL is `jdbc:hive2://localhost:10000/default`; local development does not enable authentication.

Run:

```sql
SHOW NAMESPACES IN iceberg;
SHOW TABLES IN iceberg.spark_iceberg_smoke;
SELECT * FROM iceberg.spark_iceberg_smoke.smoke_table;
DESCRIBE TABLE EXTENDED iceberg.spark_iceberg_smoke.smoke_table;
```

The S3 warehouse path is `s3a://warehouse/spark-warehouse`. To list its objects from the Metastore container, Hadoop’s S3A settings are passed directly to the command:

```powershell
docker compose exec metastore /opt/hadoop/bin/hadoop fs `
  -D fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem `
  -D fs.s3a.endpoint=http://seaweedfs:8333 `
  -D fs.s3a.endpoint.region=us-east-1 `
  -D fs.s3a.path.style.access=true `
  -D fs.s3a.connection.ssl.enabled=false `
  -D fs.s3a.access.key=spark_local `
  -D fs.s3a.secret.key=spark_local_secret `
  -D fs.s3a.aws.credentials.provider=org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider `
  -ls -R s3a://warehouse/spark-warehouse
```

Iceberg tables have metadata objects as well as data files. PostgreSQL stores the catalog records; it does not store the rows.

## Kubernetes deployment guide

See [KUBERNETES.md](KUBERNETES.md) for the numbered deployment steps. It assumes PostgreSQL is already available and describes how to deploy HMS and configure Spark and its Thrift Server without XML config files.

## Ports and development credentials

| Service | Address | Purpose |
| --- | --- | --- |
| PostgreSQL | `localhost:5432` | Hive Metastore catalog database |
| SeaweedFS S3 | `localhost:8333` | S3-compatible object storage |
| Hive Metastore | `localhost:9083` | Thrift metadata service |
| Spark Thrift Server | `localhost:10000` | Beeline and JDBC SQL endpoint |

Development credentials are `hive` / `hive_dev_password` for PostgreSQL and `spark_local` / `spark_local_secret` for S3. Replace these and use Kubernetes Secrets outside local development.

Stop containers while preserving data volumes:

```powershell
docker compose down
```

Recreate them:

```powershell
docker compose up -d --build --wait
```

`docker compose down -v` also deletes the PostgreSQL catalog, S3 objects, and Spark dependency cache.

## Licenses

Apache Spark, Apache Hive, Apache Iceberg, and SeaweedFS are Apache-2.0 projects. PostgreSQL uses the PostgreSQL License, and the PostgreSQL JDBC driver uses a BSD-style license. The container images include other dependencies with their own licenses.
