import os
import json
from django.conf import settings

# Base directory for the file-based database
DB_BASE_DIR = os.path.abspath(os.path.join(str(settings.BASE_DIR), '..', 'database'))
REQUESTS_DIR = os.path.join(DB_BASE_DIR, 'requests')
CHATS_DIR = os.path.join(DB_BASE_DIR, 'chats')
QUEUES_DIR = os.path.join(DB_BASE_DIR, 'queues')

def initialize_file_db():
    """Ensure that the database directories exist."""
    os.makedirs(DB_BASE_DIR, exist_ok=True)
    os.makedirs(REQUESTS_DIR, exist_ok=True)
    os.makedirs(CHATS_DIR, exist_ok=True)
    os.makedirs(QUEUES_DIR, exist_ok=True)

def save_request_to_file(request_id, request_data):
    """Save a request to a JSON file."""
    initialize_file_db()
    file_path = os.path.join(REQUESTS_DIR, f"request_{request_id}.json")
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(request_data, f, indent=4, default=str)
        return True
    except Exception as e:
        print(f"Error saving request {request_id} to file: {e}")
        return False

def save_chat_to_file(message_id, message_data):
    """Save a chat message to a JSON file."""
    initialize_file_db()
    file_path = os.path.join(CHATS_DIR, f"message_{message_id}.json")
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(message_data, f, indent=4, default=str)
        return True
    except Exception as e:
        print(f"Error saving chat message {message_id} to file: {e}")
        return False

def save_response_to_queue(response_id, response_data, tsp_provider):
    """Save a TSP response to its designated folder/queue."""
    initialize_file_db()
    clean_provider = str(tsp_provider).lower().strip()
    if 'airtel' in clean_provider:
        queue_name = 'airtel'
    elif 'jio' in clean_provider:
        queue_name = 'jio'
    elif 'bsnl' in clean_provider:
        queue_name = 'bsnl'
    elif 'vodafone' in clean_provider or 'vi' in clean_provider:
        queue_name = 'vodafone'
    else:
        queue_name = 'other'
        
    queue_dir = os.path.join(QUEUES_DIR, queue_name)
    os.makedirs(queue_dir, exist_ok=True)
    
    file_path = os.path.join(queue_dir, f"response_{response_id}.json")
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            json.dump(response_data, f, indent=4, default=str)
        return True
    except Exception as e:
        print(f"Error saving response {response_id} to queue {queue_name}: {e}")
        return False

def get_db_file_structure():
    """Return a dictionary of the files stored in the database folder for browsing."""
    initialize_file_db()
    structure = {
        "requests": [],
        "chats": [],
        "queues": {}
    }
    
    # List request files
    for filename in sorted(os.listdir(REQUESTS_DIR)):
        if filename.endswith('.json'):
            file_path = os.path.join(REQUESTS_DIR, filename)
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = json.load(f)
                structure["requests"].append({
                    "filename": filename,
                    "size": os.path.getsize(file_path),
                    "content": content
                })
            except Exception:
                pass

    # List chat message files
    for filename in sorted(os.listdir(CHATS_DIR)):
        if filename.endswith('.json'):
            file_path = os.path.join(CHATS_DIR, filename)
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = json.load(f)
                structure["chats"].append({
                    "filename": filename,
                    "size": os.path.getsize(file_path),
                    "content": content
                })
            except Exception:
                pass

    # List queues files
    if os.path.exists(QUEUES_DIR):
        for provider in sorted(os.listdir(QUEUES_DIR)):
            provider_path = os.path.join(QUEUES_DIR, provider)
            if os.path.isdir(provider_path):
                structure["queues"][provider] = []
                for filename in sorted(os.listdir(provider_path)):
                    if filename.endswith('.json'):
                        file_path = os.path.join(provider_path, filename)
                        try:
                            with open(file_path, 'r', encoding='utf-8') as f:
                                content = json.load(f)
                            structure["queues"][provider].append({
                                "filename": filename,
                                "size": os.path.getsize(file_path),
                                "content": content
                            })
                        except Exception:
                            pass

    return structure

import threading
import tempfile

PROCESSED_SMS_FILE = os.path.join(DB_BASE_DIR, 'processed_sms.json')
file_lock = threading.Lock()

def load_processed_sms_ids():
    """Load the list of processed SMS IDs."""
    with file_lock:
        if not os.path.exists(PROCESSED_SMS_FILE):
            return []
        try:
            with open(PROCESSED_SMS_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception as e:
            print(f"Error loading processed SMS IDs: {e}")
            return []

def save_processed_sms_ids(sms_ids):
    """Save the list of processed SMS IDs."""
    with file_lock:
        initialize_file_db()
        try:
            dir_name = os.path.dirname(PROCESSED_SMS_FILE)
            fd, temp_path = tempfile.mkstemp(dir=dir_name)
            try:
                with os.fdopen(fd, 'w', encoding='utf-8') as f:
                    json.dump(sms_ids, f, indent=4)
                os.replace(temp_path, PROCESSED_SMS_FILE)
            except Exception as ex:
                if os.path.exists(temp_path):
                    os.remove(temp_path)
                raise ex
            return True
        except Exception as e:
            print(f"Error saving processed SMS IDs: {e}")
            return False


class ProcessLock:
    def __init__(self, lock_dir):
        self.lock_dir = lock_dir

    def __enter__(self):
        import time
        # Try to acquire lock by creating the directory
        for _ in range(50):  # Timeout after 5 seconds
            try:
                os.mkdir(self.lock_dir)
                return self
            except FileExistsError:
                time.sleep(0.1)
        raise TimeoutError("Could not acquire cross-process lock on processed_sms")

    def __exit__(self, exc_type, exc_val, exc_tb):
        try:
            os.rmdir(self.lock_dir)
        except OSError:
            pass


def try_mark_sms_as_processed(sms_id):
    """
    Checks if an SMS ID is already processed.
    If it is, returns False.
    If it is not, marks it as processed, saves, and returns True.
    This operation is thread-safe and process-safe across multiple Gunicorn workers.
    """
    if not sms_id:
        return False

    lock_dir = os.path.join(DB_BASE_DIR, 'processed_sms.lock_dir')
    try:
        with ProcessLock(lock_dir):
            processed_ids = []
            if os.path.exists(PROCESSED_SMS_FILE):
                try:
                    with open(PROCESSED_SMS_FILE, 'r', encoding='utf-8') as f:
                        processed_ids = json.load(f)
                except Exception as e:
                    print(f"Error loading processed SMS IDs: {e}")

            if sms_id in processed_ids:
                return False

            processed_ids.append(sms_id)
            try:
                dir_name = os.path.dirname(PROCESSED_SMS_FILE)
                fd, temp_path = tempfile.mkstemp(dir=dir_name)
                try:
                    with os.fdopen(fd, 'w', encoding='utf-8') as f:
                        json.dump(processed_ids, f, indent=4)
                    os.replace(temp_path, PROCESSED_SMS_FILE)
                except Exception as ex:
                    if os.path.exists(temp_path):
                        os.remove(temp_path)
                    raise ex
            except Exception as e:
                print(f"Error saving processed SMS IDs: {e}")
            return True
    except TimeoutError:
        # If lock times out, assume it is currently being processed or already processed
        return False

