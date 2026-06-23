import os, sys
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
import django
django.setup()

from api.views import is_acknowledgment_message, parse_tsp_sms_response

if __name__ == '__main__':
    results = []

    # --- ACK TESTS ---
    ack_tests = [
        ("Okay",                True),
        ("okey we will inform soon",  True),
        ("Yes sir",             True),
        ("Hello",               True),
        ("Hi",                  True),
        ("Hii",                 True),
        ("\U0001f44d",          True),   # thumbs-up emoji
        ("Yes \U0001f44d",      True),   # Yes + thumbs-up
        ("\u2705",              True),   # checkmark
        ("Yes okay",            True),
        # Real data — must NOT be ack
        ("Status: Active\nCircle: Karnataka\nActivation Date: 15-Jun-2020", False),
        ("Mobile no 9876543210 is Active on Jio network. Circle: Karnataka.", False),
        ("Subscriber Active | Karnataka | Since: 12 Jan 2019 | Airtel",     False),
        ("BSNL\nSubscriber Status: Active\nSSA: Karnataka\nDOA: 15/06/2019", False),
    ]

    results.append("=== ACK TESTS ===")
    all_ok = True
    for msg, expected in ack_tests:
        result = is_acknowledgment_message(msg)
        ok = result == expected
        if not ok:
            all_ok = False
        label = "OK" if ok else "FAIL"
        safe_msg = msg.encode('ascii', errors='replace').decode()[:40]
        results.append(f"  [{label}] {repr(safe_msg)} => ack={result} (expected {expected})")

    # --- PARSE TESTS ---
    results.append("")
    results.append("=== PARSE TESTS ===")
    parse_tests = [
        ("Status: Active\nCircle: Karnataka\nActivation Date: 15-Jun-2020",
         "Airtel", "Active", "Karnataka"),
        ("Mobile no 9876543210 is Active on Jio network. Circle: Karnataka. DOA: 20-Mar-2020",
         "Jio", "Active", "Karnataka"),
        ("BSNL\nMobile: 9876543210\nSubscriber Status: Active\nSSA: Karnataka\nDOA: 15/06/2019",
         "BSNL", "Active", "Karnataka"),
        ("Number 9876543210\nStatus: Active\nCircle: Maharashtra\nActivation: 01-Jan-2019",
         "Vi", "Active", "Maharashtra"),
        # Freeform / no labels
        ("9876543210 subscriber is currently Active in Karnataka circle on Airtel",
         "Airtel", "Active", "Karnataka"),
        # Comma-separated (the old bug — split on comma destroyed parsing)
        ("Status: Active, Circle: Karnataka, Activation Date: 2020-01-15",
         "Airtel", "Active", "Karnataka"),
    ]

    for msg, tsp, exp_status, exp_circle in parse_tests:
        r = parse_tsp_sms_response(msg, tsp)
        status_ok = exp_status.lower() in r['subscriber_status'].lower()
        circle_ok = exp_circle.lower() in r['circle'].lower()
        ok = status_ok and circle_ok
        if not ok:
            all_ok = False
        label = "OK" if ok else "FAIL"
        safe_msg = msg.encode('ascii', errors='replace').decode()[:50]
        results.append(
            f"  [{label}] [{tsp}] status={r['subscriber_status']!r} circle={r['circle']!r} date={r['activation_date']}"
        )

    results.append("")
    results.append("ALL TESTS PASSED" if all_ok else "SOME TESTS FAILED")

    # Write to file (avoids Windows console encoding issues)
    out_path = os.path.join(os.path.dirname(__file__), "test_parser_results.txt")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(results))

    # Also print (ASCII-safe)
    for line in results:
        print(line.encode("ascii", errors="replace").decode())

    sys.exit(0 if all_ok else 1)
