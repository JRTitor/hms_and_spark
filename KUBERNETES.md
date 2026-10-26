# Deploy the Iceberg stack in Kubernetes

This guide follows the local Compose stack: Spark 4.0.1 + Iceberg 1.12.0, Hive Metastore 4.0.0, PostgreSQL, and S3-compatible object storage. PostgreSQL holds the Hive Metastore catalog, HMS serves Thrift on `9083`, and Spark stores Iceberg metadata/data in S3A. No HDFS cluster, `hive-site.xml`, or `core-site.xml` is needed.

## 1. Check the services Spark and HMS can reach

You need:

- PostgreSQL with a dedicated database named `iceberg_metastore` and a login such as `hive`. Keep it separate from any existing Hive catalog database; Hive 4.0.0 must not use a database already upgraded by Hive 4.0.1.
- An S3-compatible endpoint and bucket named `warehouse`. SeaweedFS works like the local stack; a cloud S3 endpoint is also fine.
- A Kubernetes namespace where HMS and Spark can resolve the PostgreSQL and S3 service names.

If the dedicated database does not exist, ask the PostgreSQL administrator to create it before starting HMS:

```sql
CREATE DATABASE iceberg_metastore OWNER hive;
```

PostgreSQL stores catalog metadata, not table data. If you have PostgreSQL and Spark but no reachable S3 service or shared persistent filesystem, add one before creating managed tables.

## 2. Build and publish the images

Build the project images and push them to a registry your cluster can access:

```sh
docker build -t <registry>/hms-iceberg:4.0.0 ./hms
docker build -t <registry>/spark-iceberg:4.0.1 ./spark
docker push <registry>/hms-iceberg:4.0.0
docker push <registry>/spark-iceberg:4.0.1
```

Use Hive 4.0.0 for HMS and Spark's Hive metastore client. Hive 4.0.1 removed legacy Thrift methods that Spark's bundled Hive client and Iceberg's HiveCatalog still call, causing `Invalid method name: 'get_table'`. The HMS image includes the PostgreSQL JDBC driver. The Hive 4.0.0 image supplies the Hadoop AWS connector on HMS's classpath. Spark downloads the matching Hadoop AWS connector and Iceberg runtime from Maven Central at startup; the cluster therefore needs Maven Central access unless those jars are included in the Spark image.

## 3. Put credentials in Kubernetes Secrets

Create or use Secrets for the PostgreSQL password and S3 access/secret keys. Inject the PostgreSQL password into HMS. Inject S3 credentials into both HMS and Spark. In a production cluster, use the platform's secret manager or workload identity where available; do not commit development credentials into a Deployment.

Use these internal service addresses in the next steps:

```text
PostgreSQL: postgres.<namespace>.svc.cluster.local:5432
S3:        <s3-service>.<namespace>.svc.cluster.local:8333
HMS:       hms.<namespace>.svc.cluster.local:9083
```

Replace names and ports with the services in your cluster. For AWS S3, use the bucket's AWS endpoint and the appropriate credentials provider instead of the SeaweedFS example settings below.

## 4. Start Hive Metastore

Run one HMS pod initially and expose it with a ClusterIP Service on port `9083`. Use image `<registry>/hms-iceberg:4.0.0` and set `DB_DRIVER=postgres`. The container needs the PostgreSQL JDBC driver and `HADOOP_CLASSPATH=/opt/hadoop/share/hadoop/tools/lib/*`.

In the container's command/args, pass the database settings to Hive as JVM options, then initialize or upgrade the schema and start Metastore. For example, the shell command in the Deployment can follow this sequence; obtain the password from a Secret-backed environment variable:

```sh
export HIVE_CONF_DIR=/opt/hive/conf
export HADOOP_CLIENT_OPTS="-Xmx1G \
  -Djavax.jdo.option.ConnectionDriverName=org.postgresql.Driver \
  -Djavax.jdo.option.ConnectionURL=jdbc:postgresql://postgres.<namespace>.svc.cluster.local:5432/iceberg_metastore \
  -Djavax.jdo.option.ConnectionUserName=hive \
  -Djavax.jdo.option.ConnectionPassword=$POSTGRES_PASSWORD \
  -Dhive.metastore.warehouse.dir=s3a://warehouse/spark-warehouse \
  -Dmetastore.try.direct.sql.ddl=false"
export HADOOP_CLASSPATH=/opt/hadoop/share/hadoop/tools/lib/*

/opt/hive/bin/schematool -dbType postgres -initOrUpgradeSchema
exec /opt/hive/bin/hive --skiphadoopversion --skiphbasecp --service metastore \
  --hiveconf hive.metastore.warehouse.dir=s3a://warehouse/spark-warehouse \
  --hiveconf fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem \
  --hiveconf fs.s3a.endpoint=http://<s3-service>.<namespace>.svc.cluster.local:8333 \
  --hiveconf fs.s3a.endpoint.region=us-east-1 \
  --hiveconf fs.s3a.path.style.access=true \
  --hiveconf fs.s3a.connection.ssl.enabled=false \
  --hiveconf fs.s3a.access.key=$S3_ACCESS_KEY \
  --hiveconf fs.s3a.secret.key=$S3_SECRET_KEY \
  --hiveconf fs.s3a.aws.credentials.provider=org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider
```

Run schema initialization against a new/empty Hive schema. For an existing initialized schema, validate it with `/opt/hive/bin/schematool -dbType postgres -validate` rather than initializing it again. Hive's schema tool supports the PostgreSQL connection details through command-line options as well. [Hive schema tool](https://hive.apache.org/docs/latest/admin/hive-schema-tool/)

## 5. Configure Spark for Iceberg and the Hive catalog

Pass these properties to the Spark Thrift Server or to every Spark application that must use the catalog. They can be Spark Operator `sparkConf` values or `spark-submit --conf` arguments:

```text
spark.sql.catalogImplementation=hive
spark.sql.hive.metastore.version=4.0.0
spark.sql.hive.metastore.jars=maven
spark.hive.metastore.uris=thrift://hms.<namespace>.svc.cluster.local:9083
spark.hive.metastore.warehouse.dir=s3a://warehouse/spark-warehouse
spark.sql.warehouse.dir=s3a://warehouse/spark-warehouse

spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
spark.sql.catalog.iceberg=org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.iceberg.type=hive
spark.sql.catalog.iceberg.uri=thrift://hms.<namespace>.svc.cluster.local:9083
spark.sql.catalog.iceberg.warehouse=s3a://warehouse/spark-warehouse
spark.sql.catalog.iceberg.io-impl=org.apache.iceberg.hadoop.HadoopFileIO

spark.jars.packages=org.apache.hadoop:hadoop-aws:3.4.1,org.apache.iceberg:iceberg-spark-runtime-4.0_2.13:1.12.0
spark.jars.ivy=/opt/spark/ivy
spark.driver.extraJavaOptions=-Duser.home=/opt/spark/ivy
spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem
spark.hadoop.fs.s3a.endpoint=http://<s3-service>.<namespace>.svc.cluster.local:8333
spark.hadoop.fs.s3a.endpoint.region=us-east-1
spark.hadoop.fs.s3a.path.style.access=true
spark.hadoop.fs.s3a.connection.ssl.enabled=false
spark.hadoop.fs.s3a.aws.credentials.provider=org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider
```

Set `spark.hadoop.fs.s3a.access.key` and `spark.hadoop.fs.s3a.secret.key` from the S3 credentials. The Spark driver and executors must all receive the S3 configuration and credentials. If using environment-based credentials with Hadoop 3.4.1, use its AWS SDK v2 environment provider and expose `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` to the driver and executors. [Hadoop S3A authentication](https://hadoop.apache.org/docs/r3.4.1/hadoop-aws/tools/hadoop-aws/authentication.html)

The Iceberg runtime artifact shown is for Spark 4.0 / Scala 2.13; choose the corresponding runtime artifact if your Spark version differs. [Iceberg Spark runtimes](https://iceberg.apache.org/releases/) The Hive catalog configuration is documented by [Apache Iceberg](https://iceberg.apache.org/docs/latest/spark-configuration/).

## 6. Expose Spark Thrift Server if JDBC clients need it

Start Spark with `/opt/spark/bin/spark-submit --class org.apache.spark.sql.hive.thriftserver.HiveThriftServer2 --master 'local[*]'`, pass every Spark property in step 5 as `--conf key=value`, then add `--hiveconf hive.server2.thrift.bind.host=0.0.0.0 --hiveconf hive.server2.thrift.port=10000`. Create a ClusterIP Service on port `10000`. DBeaver or Beeline can connect through a port-forward or an approved internal route. `local[*]` runs Spark inside that pod rather than scheduling separate Kubernetes executors.

## 7. Verify the deployment

Check the pods and services:

```sh
kubectl get pods,services -n <namespace>
kubectl logs deployment/hms -n <namespace>
kubectl logs deployment/spark-thrift -n <namespace>
```

Port-forward Spark Thrift Server and run the same SQL as the local smoke test:

```sh
kubectl port-forward service/spark-thrift 10000:10000 -n <namespace>
```

```sql
CREATE NAMESPACE iceberg.k8s_check;
CREATE TABLE iceberg.k8s_check.sample (id BIGINT, message STRING) USING iceberg;
INSERT INTO iceberg.k8s_check.sample VALUES (1, 'ok');
SELECT * FROM iceberg.k8s_check.sample;
```

Confirm the namespace/table are visible through Spark and recorded in PostgreSQL, and that Iceberg metadata and data objects appear beneath the warehouse bucket. PostgreSQL contains the catalog records; S3 contains the Iceberg metadata and data files.
