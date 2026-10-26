FROM apache/spark:4.0.1

# The named volumes need writable mount points for Spark's non-root user.
USER root
RUN mkdir -p /opt/spark/ivy && chown -R spark:spark /opt/spark/ivy
USER spark
