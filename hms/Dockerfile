FROM apache/hive:4.0.0

# Hive Metastore uses this JDBC driver to connect to PostgreSQL.
USER root
ADD --checksum=sha256:31fbf6f06b2217fb51d5100cee51b22625cc81640da0679b47914e54c1e6377c https://repo.maven.apache.org/maven2/org/postgresql/postgresql/42.7.12/postgresql-42.7.12.jar /opt/hive/lib/postgres.jar
RUN chown hive:hive /opt/hive/lib/postgres.jar && chmod 0644 /opt/hive/lib/postgres.jar

USER hive
