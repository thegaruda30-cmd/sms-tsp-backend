"""
Apply the Supabase schema directly via PostgreSQL connection.
"""
import subprocess
import sys

# Install psycopg2-binary if not already available
try:
    import psycopg2
    print("psycopg2 already available.")
except ImportError:
    print("Installing psycopg2-binary...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "psycopg2-binary"])
    import psycopg2

import os

# ── Supabase connection details ──────────────────────────────────────────────
DB_HOST     = "db.sargsmajubzlwtwvgyeq.supabase.co"
DB_PORT     = 5432
DB_NAME     = "postgres"
DB_USER     = "postgres"
DB_PASSWORD = "smsforward@system"

# Path to the schema SQL file (same directory as this script)
SCHEMA_FILE = os.path.join(os.path.dirname(__file__), "supabase_schema.sql")

def apply_schema():
    print(f"\n{'='*60}")
    print("  Connecting to Supabase PostgreSQL...")
    print(f"{'='*60}")

    with open(SCHEMA_FILE, "r", encoding="utf-8") as f:
        sql = f.read()

    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD,
            connect_timeout=15,
            sslmode="require"
        )
        conn.autocommit = True
        cur = conn.cursor()

        print("  Connected successfully!\n")
        print("  Applying schema...")

        # Execute the full SQL schema
        cur.execute(sql)

        print("\n  Verifying tables created...")
        cur.execute("""
            SELECT tablename
            FROM pg_tables
            WHERE schemaname = 'public'
            ORDER BY tablename;
        """)
        tables = [row[0] for row in cur.fetchall()]

        expected = [
            "admin_forward_requests",
            "admin_forward_responses",
            "officer_received_responses",
            "request_status_logs",
            "requests",
            "tsp_responses",
            "users",
            "tsp_settings",
        ]

        print("\n" + "="*60)
        print("  Tables in public schema:")
        print("="*60)
        for t in tables:
            status = "OK" if t in expected else "  "
            print(f"  [{status}] {t}")

        missing = [t for t in expected if t not in tables]
        if missing:
            print(f"\n  [WARN] Missing tables: {missing}")
        else:
            print("\n  [SUCCESS] All 8 tables created successfully!")

        cur.close()
        conn.close()

    except psycopg2.OperationalError as e:
        print(f"\n  [ERR] Connection failed: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\n  [ERR] Error applying schema: {e}")
        sys.exit(1)

if __name__ == "__main__":
    apply_schema()
