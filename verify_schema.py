import psycopg2

conn = psycopg2.connect(
    host="db.sargsmajubzlwtwvgyeq.supabase.co",
    port=5432,
    dbname="postgres",
    user="postgres",
    password="smsforward@system",
    sslmode="require"
)
cur = conn.cursor()

# Check tables
cur.execute("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename")
tables = [r[0] for r in cur.fetchall()]

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

print("\n" + "="*55)
print("  Supabase Table Verification")
print("="*55)
for t in tables:
    tag = "[OK]" if t in expected else "[  ]"
    print(f"  {tag} {t}")

missing = [t for t in expected if t not in tables]
print()
if missing:
    print(f"  [WARN] Missing tables: {missing}")
else:
    print("  [SUCCESS] All 8 tables exist in Supabase!")

# Check indexes
cur.execute("""
    SELECT indexname, tablename
    FROM pg_indexes
    WHERE schemaname = 'public'
    ORDER BY tablename, indexname
""")
indexes = cur.fetchall()
print(f"\n  Total indexes: {len(indexes)}")

# Check RLS policies
cur.execute("""
    SELECT tablename, policyname
    FROM pg_policies
    WHERE schemaname = 'public'
    ORDER BY tablename
""")
policies = cur.fetchall()
print(f"  Total RLS policies: {len(policies)}")
print("="*55 + "\n")

cur.close()
conn.close()
