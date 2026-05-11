import os
import subprocess
import tempfile
import functions_framework

@functions_framework.cloud_event
def run_backup(cloud_event):
    print(f"Triggered by event: {cloud_event['id']}")
    
    # Restic environments are expected to be set via Secret Manager / Env vars
    # Required: RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
    
    source_bucket = os.environ.get('SOURCE_BUCKET') # e.g. gs://my-bucket
    
    with tempfile.TemporaryDirectory() as tmpdir:
        # 1. Sync bucket to local temp dir (restic works best on local files for GCS source)
        # Alternatively, restic can use rclone as a backend, but for a small blog, 
        # syncing to a temp dir is simpler.
        print(f"Syncing {source_bucket} to {tmpdir}...")
        subprocess.run(['gsutil', '-m', 'rsync', '-r', source_bucket, tmpdir], check=True)
        
        # 2. Run restic backup
        print("Starting restic backup to R2...")
        # Note: In a real environment, you'd ensure the restic binary is in the path.
        # We'll use a wrapper or ensure it's in the container.
        try:
            result = subprocess.run(
                ['restic', 'backup', tmpdir, '--tag', 'gcs-trigger'],
                capture_output=True,
                text=True,
                check=True
            )
            print(result.stdout)
        except subprocess.CalledProcessError as e:
            print(f"Restic failed: {e.stderr}")
            raise e

    print("Backup completed successfully.")
