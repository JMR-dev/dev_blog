import os
import subprocess
import tempfile
import logging
import functions_framework
from opentelemetry import _logs
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.sdk.resources import Resource

# ---------------------------------------------------------------------------
# OTEL Logging Setup
# ---------------------------------------------------------------------------
resource = Resource.create({
    "service.name": "dev-blog-backup",
    "deployment.environment": os.environ.get("ENVIRONMENT", "production")
})
logger_provider = LoggerProvider(resource=resource)
_logs.set_logger_provider(logger_provider)

# Export logs via OTLP (async/non-blocking via BatchLogRecordProcessor)
exporter = OTLPLogExporter()
logger_provider.add_log_record_processor(BatchLogRecordProcessor(exporter))

# Attach OTEL handler to the root logger
otel_handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
root_logger = logging.getLogger()
root_logger.addHandler(otel_handler)

# Create a logger for this module
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# Disable the default stream handler for GCP to minimize billable logs
# By setting the root logger to WARNING, we ensure that standard output
# (captured by GCP) only contains high-priority logs.
# We also want to make sure we don't duplicate logs.
for handler in root_logger.handlers:
    if not isinstance(handler, LoggingHandler):
        handler.setLevel(logging.WARNING)

root_logger.setLevel(logging.WARNING)

@functions_framework.cloud_event
def run_backup(cloud_event):
    logger.info(f"Triggered by event: {cloud_event['id']}")
    
    # Restic environments are expected to be set via Secret Manager / Env vars
    source_bucket = os.environ.get('SOURCE_BUCKET')
    r2_account_id = os.environ.get('R2_ACCOUNT_ID')
    r2_bucket = os.environ.get('R2_BUCKET')
    
    # Construct the Restic repository URL for Cloudflare R2
    os.environ['RESTIC_REPOSITORY'] = f"s3:https://{r2_account_id}.r2.cloudflarestorage.com/{r2_bucket}"
    
    with tempfile.TemporaryDirectory() as tmpdir:
        logger.info(f"Syncing {source_bucket} to {tmpdir}...")
        try:
            subprocess.run(['gsutil', '-m', 'rsync', '-r', source_bucket, tmpdir], check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as e:
            logger.error(f"Sync failed: {e.stderr}")
            raise e
        
        logger.info("Starting restic backup to R2...")
        try:
            result = subprocess.run(
                ['restic', 'backup', tmpdir, '--tag', 'gcs-trigger'],
                capture_output=True,
                text=True,
                check=True
            )
            logger.info(result.stdout)
        except subprocess.CalledProcessError as e:
            logger.error(f"Restic failed: {e.stderr}")
            raise e

    logger.info("Backup completed successfully.")
    # Ensure logs are flushed before the function exits
    logger_provider.force_flush()
