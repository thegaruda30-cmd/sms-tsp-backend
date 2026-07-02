# type: ignore
# mypy: ignore-errors
from django.shortcuts import get_object_or_404
from django.utils import timezone

from django.db.models import Count, Q, F, Prefetch
from django.http import HttpResponse
from django.core.cache import cache

from rest_framework import status, views, viewsets, permissions, serializers
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.authtoken.views import ObtainAuthToken
from rest_framework.authtoken.models import Token

import pandas as pd
import io

# Imports for PDF generation
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib import colors

from api.models import (
    User, TSPProvider, Request, RequestStatus, RequestStatusLog,
    TSPResponse, PermissionSetting, SystemNotification, ActivityLog, SystemSetting, UserRole, ChatMessage, SMSLog,
    AdminForwardRequest, TspSetting, PasswordResetRequest
)
from api.serializers import (
    UserSerializer, TSPProviderSerializer, RequestSerializer,
    RequestStatusLogSerializer, TSPResponseSerializer, PermissionSettingSerializer,
    SystemNotificationSerializer, ActivityLogSerializer, ChatMessageSerializer, SMSLogSerializer,
    TspSettingSerializer, PasswordResetRequestSerializer
)
from api.file_db import save_request_to_file, save_chat_to_file, get_db_file_structure, save_response_to_queue
from api.supabase_db import (
    async_sync_user, async_save_request, async_save_admin_forward_request,
    async_save_tsp_response, async_save_admin_forward_response, async_log_status,
    async_sync_tsp_setting, async_delete_tsp_setting, async_sync_tsp_provider_as_setting,
)

# Helper functions for logging and notifications
def log_activity(action_name, user, request=None, details=None):
    ActivityLog.objects.create(action=action_name, user=user, request=request, details=details)

def create_notification(user, title, message):
    SystemNotification.objects.create(user=user, title=title, message=message)

def notify_admins(title, message):
    admins = User.objects.filter(role=UserRole.ADMIN)
    for admin in admins:
        create_notification(admin, title, message)

import json
import urllib.request
import threading
from django.conf import settings

def format_phone_number(num):
    if not num:
        return ""
    num = str(num).strip()
    if num.startswith('+'):
        return num
    if len(num) == 10 and num.isdigit():
        return f"+91{num}"
    return num

import time

LAST_POLL_TIME = 0

def normalize_phone(num):
    if not num:
        return ""
    digits = "".join([c for c in str(num) if c.isdigit()])
    if len(digits) >= 10:
        return digits[-10:]
    return digits

def is_acknowledgment_message(message):
    """
    Returns True ONLY if this message is a pure acknowledgment (TSP saying
    "we received your request, please wait") with NO actual subscriber data.

    Handles all common TSP ack patterns for Airtel, Jio, Vi, BSNL:
    - Emoji-only replies (👍, ✅, 🙏)
    - Short word replies (ok, okey, noted, yes, hii, hello, hi)
    - Multi-word ack phrases (please wait, we will inform, etc.)
    - Greetings with no data
    """
    import re as _re
    message_clean = message.lower().strip()
    # Strip all emoji and punctuation to get the text-only content
    text_only = _re.sub(r'[^\w\s]', '', message_clean).strip()
    # Strip all whitespace+emoji to check if it's purely emoji/symbols
    no_emoji_no_space = _re.sub(r'[\W_]', '', message_clean)

    # --- Subscriber/data keys that prove this is a real data response ---
    subscriber_keys = [
        "status:", "status :",
        "subscriber status",
        "user status",
        "active", "suspended", "deactivated", "inactive",
        "circle:", "circle :",
        "state:", "state :",
        "activation date", "activated on", "activation:",
        "registered",
        "customer name", "customer:",
        "mobile number:", "mob no", "mobile no",
        "sim", "imsi", "imei",
        "subscriber",
        "plan:", "plan :",
        "prepaid", "postpaid",
        "operator:",
        "service status",
        "network:",
        "jio", "airtel", "bsnl", "vodafone", "idea",
        "done", "completed", "processed", "donee",
    ]

    has_subscriber_data = any(key in message_clean for key in subscriber_keys)

    # If there is subscriber data, it is NEVER an ack — it is a real response
    if has_subscriber_data:
        return False

    # Pure emoji / symbol / thumbs-up only messages are acks
    emoji_ack_pattern = _re.compile(
        r'^[\U0001F300-\U0001FFFE\u2600-\u27BF\u2300-\u23FF\s✅👍🙏☑️🤝]*$',
        _re.UNICODE
    )
    if emoji_ack_pattern.match(message.strip()) or not text_only:
        return True

    # Exact-match short acks (full message is one of these)
    quick_acks = {
        "okay", "okey", "okk", "ok", "noted", "received", "wait",
        "processing", "under process", "yes", "yep", "yup",
        "sure", "hi", "hii", "hiii", "hello", "helo",
        "thanks", "thank you", "noted thanks", "ok thanks",
        "yes sir", "ok sir", "noted sir", "received sir",
        "yes okay", "yes ok", "yes noted", "received noted",
    }
    if text_only in quick_acks or message_clean in quick_acks:
        return True

    # Short messages (<=20 chars after stripping) with no subscriber data are acks
    # (Disabled because short subscriber data like cell IDs e.g. "lp5757" do not have subscriber keywords but are final replies)
    # if len(text_only) <= 20 and not has_subscriber_data:
    #     return True

    # --- Strong, multi-word ack phrases that are unambiguous ---
    strong_ack_phrases = [
        "we will inform",
        "will inform you",
        "we will get back",
        "being processed",
        "working on it",
        "process shortly",
        "please wait",
        "we will reply",
        "we will respond",
        "request is being",
        "request has been received",
        "we have received your",
        "will be provided shortly",
        "team will revert",
        "inform you shortly",
        "will update you",
        "will get back to you",
        "checking your details",
        "checking details",
        "looking into it",
    ]

    if any(phrase in message_clean for phrase in strong_ack_phrases):
        return True

    return False


def parse_tsp_sms_response(message, tsp_name=''):
    """
    Parse a TSP SMS response into structured fields.
    Handles Airtel, Jio, Vi (Vodafone Idea), and BSNL response formats.

    Returns a dict with:
        subscriber_status, circle, activation_date, additional_notes
    All values default to empty string / None — never the full raw message.
    """
    import re as _re
    from datetime import datetime as _dt

    result = {
        'subscriber_status': '',
        'circle': '',
        'activation_date': None,
        'additional_notes': '',
    }

    msg = message.strip()
    msg_lower = msg.lower()
    tsp_lower = tsp_name.lower()

    # ── Determine TSP from name or message content ──────────────────────────
    is_airtel = 'airtel' in tsp_lower or 'airtel' in msg_lower or 'bharti' in msg_lower
    is_jio    = 'jio' in tsp_lower or 'jio' in msg_lower or 'reliance' in msg_lower
    is_vi     = 'vi' in tsp_lower or 'vodafone' in msg_lower or 'idea' in msg_lower or 'vi\n' in msg_lower
    is_bsnl   = 'bsnl' in tsp_lower or 'bsnl' in msg_lower or 'bharat sanchar' in msg_lower

    # ── Helper: try many date formats ───────────────────────────────────────
    def _parse_date(val):
        val = val.strip()
        # ISO format: 2023-06-15
        m = _re.search(r'\d{4}-\d{2}-\d{2}', val)
        if m:
            try: return _dt.strptime(m.group(0), '%Y-%m-%d').date()
            except: pass
        for fmt in ('%d %b %Y', '%d %B %Y', '%Y/%m/%d', '%d-%m-%Y',
                    '%d/%m/%Y', '%b %d, %Y', '%B %d, %Y',
                    '%d-%b-%Y', '%d.%m.%Y', '%m/%d/%Y'):
            try: return _dt.strptime(val, fmt).date()
            except: pass
        return None

    # ── Helper: extract value for a key label ───────────────────────────────
    def _extract(pattern, text, group=1, default=''):
        m = _re.search(pattern, text, _re.IGNORECASE)
        return m.group(group).strip() if m else default

    # ── Split message into lines ─────────────────────────────────────────────
    # Split ONLY on newlines and semicolons — NOT on commas, because many TSPs
    # put comma-separated info on one line (e.g. "Active, Karnataka, 01-Jan-2020")
    lines = _re.split(r'[\n;|]', msg)

    # ── Generic key-value extraction (works for all TSPs) ───────────────────
    for line in lines:
        line = line.strip()
        if ':' not in line:
            continue
        parts = line.split(':', 1)
        key = parts[0].strip().lower()
        val = parts[1].strip()
        if not val:
            continue

        # Status variants
        if _re.search(r'\b(status|user status|subscriber status|service status|connection status)\b', key):
            if not result['subscriber_status']:
                result['subscriber_status'] = val

        # Circle / State / Zone / Region
        elif _re.search(r'\b(circle|state|zone|region|lsa|location)\b', key):
            if not result['circle']:
                result['circle'] = val

        # Activation / registration date
        elif _re.search(r'\b(activation|activated|registration|registered|reg date|doa|date of activation|sim activation|since)\b', key):
            if not result['activation_date']:
                result['activation_date'] = _parse_date(val)

        # Customer name
        elif _re.search(r'\b(customer name|subscriber name|name|cust name)\b', key):
            existing = result['additional_notes']
            result['additional_notes'] = f"Customer Name: {val}" + (f"\n{existing}" if existing else '')

        # Plan / Package
        elif _re.search(r'\b(plan|package|tariff|offer)\b', key):
            existing = result['additional_notes']
            note = f"Plan: {val}"
            result['additional_notes'] = (existing + '\n' + note) if existing else note

        # Operator / Network
        elif _re.search(r'\b(operator|network|isp|provider)\b', key):
            if not is_airtel and not is_jio and not is_vi and not is_bsnl:
                # Use as TSP hint if not already known
                pass
            existing = result['additional_notes']
            note = f"Operator: {val}"
            result['additional_notes'] = (existing + '\n' + note) if existing else note

        # Notes / Remarks / Others
        elif _re.search(r'\b(note|remark|comment|info|additional|other|detail)\b', key):
            existing = result['additional_notes']
            result['additional_notes'] = (existing + '\n' + val) if existing else val

    # ── Second pass: comma-split lines that have multiple key:value pairs ────
    # Handles: "Status: Active, Circle: Karnataka, Activation Date: 2020-01-15"
    for line in lines:
        line = line.strip()
        # Only bother if there are multiple colons (multiple kv pairs on one line)
        if line.count(':') < 2:
            continue
        # Split on comma, then treat each segment as a potential key:value
        segments = _re.split(r',\s*', line)
        for seg in segments:
            seg = seg.strip()
            if ':' not in seg:
                continue
            parts = seg.split(':', 1)
            key = parts[0].strip().lower()
            val = parts[1].strip()
            if not val:
                continue
            if _re.search(r'\b(status|user status|subscriber status|service status|connection status)\b', key):
                if not result['subscriber_status']:
                    result['subscriber_status'] = val
            elif _re.search(r'\b(circle|state|zone|region|lsa|location)\b', key):
                if not result['circle']:
                    result['circle'] = val
            elif _re.search(r'\b(activation|activated|registration|registered|reg date|doa|date of activation|sim activation|since)\b', key):
                if not result['activation_date']:
                    result['activation_date'] = _parse_date(val)

    # ── TSP-Specific pattern overrides ───────────────────────────────────────

    # ─── AIRTEL patterns ──────────────────────────────────────────────────────
    # Airtel typically sends: "Status: Active\nCircle: Karnataka\nActivation Date: 15-Jun-2020"
    # or: "Subscriber Active | Karnataka | Since: 12 Jan 2019 | Airtel"
    if is_airtel:
        # Subscriber active/inactive inline (e.g. "Subscriber Active")
        if not result['subscriber_status']:
            m = _re.search(r'subscriber\s+(active|inactive|suspended|deactivated|live|disconnected)', msg, _re.IGNORECASE)
            if m:
                result['subscriber_status'] = m.group(1).capitalize()

        # "Since: DD-Mon-YYYY" pattern
        if not result['activation_date']:
            m = _re.search(r'since[:\s]+([\w\s,/-]+?)(?:\s*\||\s*\n|$)', msg, _re.IGNORECASE)
            if m:
                result['activation_date'] = _parse_date(m.group(1))

    # ─── JIO patterns ─────────────────────────────────────────────────────────
    # Jio often sends: "Mobile: XXXXXXXXXX\nStatus: Active\nPlan: Rs 239 / 28 Days\nCircle: Karnataka"
    # or flat: "Mobile no XXXXXXXXXX is Active on Jio network. Circle: Karnataka. DOA: 20-Mar-2020"
    if is_jio:
        if not result['subscriber_status']:
            # Inline: "is Active on Jio"
            m = _re.search(r'is\s+(active|inactive|suspended|deactivated|barred|live)', msg, _re.IGNORECASE)
            if m:
                result['subscriber_status'] = m.group(1).capitalize()

        if not result['activation_date']:
            # DOA: pattern
            m = _re.search(r'\bDOA[:\s]+([\w\s,/-]+?)(?:\.|\n|$)', msg, _re.IGNORECASE)
            if m:
                result['activation_date'] = _parse_date(m.group(1))

        if not result['circle']:
            # "Circle: Karnataka" or "Karnataka circle"
            m = _re.search(r'([A-Z][a-z]+(?:\s[A-Z][a-z]+)?)\s+circle', msg, _re.IGNORECASE)
            if m:
                result['circle'] = m.group(1).strip()

    # ─── VI / Vodafone Idea patterns ─────────────────────────────────────────
    # Vi often sends: "Number XXXXXXXXXX\nStatus: Active\nCircle: Maharashtra\nActivation: 01-Jan-2019"
    # or senders start with VX-
    if is_vi:
        if not result['subscriber_status']:
            m = _re.search(r'\b(active|inactive|suspended|deactivated|live|ported out|churned)\b', msg, _re.IGNORECASE)
            if m:
                # Make sure it's not part of a different phrase
                result['subscriber_status'] = m.group(1).capitalize()

        if not result['activation_date']:
            m = _re.search(r'(?:activation|activated|since|doa)[:\s]+([\d\w\s,/-]+?)(?:\.|\n|$)', msg, _re.IGNORECASE)
            if m:
                result['activation_date'] = _parse_date(m.group(1))

    # ─── BSNL patterns ───────────────────────────────────────────────────────
    # BSNL often sends: "BSNL\nMobile: XXXXXXXXXX\nSubscriber Status: Active\nSSA: Karnataka\nDOA: 15/06/2019"
    if is_bsnl:
        if not result['subscriber_status']:
            m = _re.search(r'\b(active|inactive|suspended|deactivated|ported|churned|live|disconnected)\b', msg, _re.IGNORECASE)
            if m:
                result['subscriber_status'] = m.group(1).capitalize()

        if not result['circle'] :
            # BSNL uses SSA (Secondary Service Area) for circle
            m = _re.search(r'\bSSA[:\s]+([\w\s]+?)(?:\.|\n|$)', msg, _re.IGNORECASE)
            if m:
                result['circle'] = m.group(1).strip()

        if not result['activation_date']:
            m = _re.search(r'\bDOA[:\s]+([\d/\-\w\s,]+?)(?:\.|\n|$)', msg, _re.IGNORECASE)
            if m:
                result['activation_date'] = _parse_date(m.group(1))

    # ── Final fallback: if still no status, search for known status words ────
    # This catches cases where the TSP sends a freeform message without labels
    if not result['subscriber_status']:
        m = _re.search(
            r'\b(active|inactive|suspended|deactivated|live|barred|disconnected|ported out|churned|in service|out of service|not registered|registered)\b',
            msg, _re.IGNORECASE
        )
        if m:
            result['subscriber_status'] = m.group(1).capitalize()

    # ── Final fallback: freeform circle extraction ────────────────────────────
    # Catches "Karnataka circle", "Active in Karnataka circle on Airtel", etc.
    if not result['circle']:
        m = _re.search(
            r'\b([A-Za-z]+(?:\s[A-Za-z]+)?)\s+circle\b',
            msg, _re.IGNORECASE
        )
        if m:
            result['circle'] = m.group(1).strip()

    # ── Clean up and sanitize ────────────────────────────────────────────────
    # Trim whitespace from all string fields
    result['subscriber_status'] = result['subscriber_status'].strip()
    result['additional_notes'] = result['additional_notes'].strip()

    # Clean circle: strip trailing ". KEY: value" fragments (dot-separated sentences)
    circle = result['circle'].strip()
    if circle:
        # Remove anything after the first period followed by an uppercase word
        circle = _re.sub(r'\.\s+[A-Z].*$', '', circle).strip()
        # Remove leading articles like "in "
        circle = _re.sub(r'^(in|of|for|at|from)\s+', '', circle, flags=_re.IGNORECASE).strip()
    result['circle'] = circle

    # If we couldn't extract a clean status, mark as Unknown rather than
    # dumping the full raw SMS body into the status field
    if not result['subscriber_status']:
        result['subscriber_status'] = 'Unknown'

    return result


def is_promotional_or_spam_sms(message: str) -> bool:
    """
    Returns True if the SMS is clearly promotional, marketing, OTP, or spam
    and should NOT be stored as a TSP service response.

    Only unmatched SMS (those with no linked Request) go through this filter.
    If a request IS matched by ticket ID or mobile number, it is ALWAYS saved
    regardless of content.
    """
    import re as _re

    msg_lower = message.lower()

    # ── 1. OTP / Verification codes ─────────────────────────────────────────
    otp_patterns = [
        r'\botp\b', r'one.?time.?password', r'verification code',
        r'authentication code', r'login code', r'passcode', r'\d{4,8} is your',
        r'do not share.*code', r'never share.*otp',
    ]
    for p in otp_patterns:
        if _re.search(p, msg_lower):
            return True

    # ── 2. Promotional / marketing indicators ────────────────────────────────
    promo_keywords = [
        # Offers & recharge
        'recharge', 'rc99', 'rc149', 'rc299', 'unlimited data', 'gb/d',
        '1gb/', '2gb/', '3gb/', 'per day', 'validity', 'get rs.', 'get rs ',
        'off on rs', '% off', 'cashback', 'free data', 'free call',
        'exciting offer', 'special offer', 'best offer', 'extra benefit',
        'daily data', 'data benefit', 'plan benefit',
        # Entertainment / shopping
        'movie', 'series', 'tv show', 'watch on', 'stream', 'zee5', 'hotstar',
        'amazon prime', 'netflix', 'football world cup', 'ipl', 'cricket',
        'vi app', 'viapp', 'airtel thanks', 'jio cinema', 'bsnl portal',
        'shop', 'shopping', 'discount', 'coupon', 'voucher', 'sale',
        # Update / account promo nudges
        'update your email', 'update your alt', 'whatsapp:',
        'head to whatsapp', 'download app', 'install app',
        # Generic promo openers
        'dear bata', 'dear valued', 'dear member', 'congratulations',
        'you have won', 'lucky draw',
    ]
    for kw in promo_keywords:
        if kw in msg_lower:
            return True

    # ── 3. URLs / links (strong indicator of spam/promo) ────────────────────
    url_patterns = [
        r'https?://', r'www\.', r'\.onelink\.me', r'\.me/', r'bit\.ly',
        r'tinyurl', r'wa\.me', r'viapp\.', r'airtel\.in', r'jio\.com',
        r'bsnl\.co\.in',
    ]
    for p in url_patterns:
        if _re.search(p, msg_lower):
            return True

    # ── 4. Short promotional sender patterns ────────────────────────────────
    # (These checks are for cases where the sender is an AD- or TM- sender ID)
    # We do NOT block JD-, VM-, DM- etc. since those can be service-related.
    # This check is intentionally lenient — just flag obvious ad senders.

    # ── Not spam ─────────────────────────────────────────────────────────────
    return False


def process_single_received_sms(sms_id, sender, message, received_at_str):

    import re
    from api.models import User, UserRole
    admin_user = User.objects.filter(role=UserRole.ADMIN).first()

    # Filter to only allow SMS from active TSP numbers
    sender_clean = normalize_phone(sender)
    is_tsp_sender = False
    for tsp in TSPProvider.objects.filter(is_active=True):
        if normalize_phone(tsp.mobile_number) == sender_clean:
            is_tsp_sender = True
            break

    if not is_tsp_sender:
        return False

    # ── Mandatory debug logging ───────────────────────────────────────────────
    try:
        print(f"[TSP RESPONSE] Incoming SMS id={sms_id} from={sender}")
        print(f"[TSP RESPONSE] Message content: {message[:200]}")
    except Exception:
        try:
            print(f"[TSP RESPONSE] Incoming SMS id={sms_id} from={sender}")
            print(f"[TSP RESPONSE] Message content: {message[:200].encode('ascii', errors='replace').decode('ascii')}")
        except Exception:
            pass
    # ─────────────────────────────────────────────────────────────────────────

    req = None

    # 1. Match by Ticket ID in the message body
    ticket_match = re.search(r'TSPTKT-(\d+)', message, re.IGNORECASE)
    if ticket_match:
        ticket_id = f"TSPTKT-{int(ticket_match.group(1)):06d}"
        req = Request.objects.filter(ticket_id=ticket_id).first()

    # 2. Match by customer phone number in the message
    if not req:
        # Extract sequences of 10 to 12 digits, and extract the last 10 digits of each sequence
        raw_matches = re.findall(r'\d{10,12}', message)
        phone_matches = [p[-10:] for p in raw_matches]
        if phone_matches:
            sender_clean = normalize_phone(sender)
            matching_tsps = []
            for tsp in TSPProvider.objects.filter(is_active=True):
                if normalize_phone(tsp.mobile_number) == sender_clean:
                    matching_tsps.append(tsp)
            
            # Resolve ambiguity if multiple TSPs share the same phone number
            if len(matching_tsps) > 1:
                message_lower = message.lower()
                has_jio = bool(re.search(r'\bjio\b|\breliance\b', message_lower))
                has_airtel = bool(re.search(r'\bairtel\b|\bbharti\b', message_lower))
                has_bsnl = bool(re.search(r'\bbsnl\b', message_lower))
                has_vi = bool(re.search(r'\bvi\b|\bvodafone\b|\bidea\b', message_lower))
                
                detected_ops = []
                if has_jio: detected_ops.append('JIO')
                if has_airtel: detected_ops.append('AIRTEL')
                if has_bsnl: detected_ops.append('BSNL')
                if has_vi: detected_ops.append('VI')
                if len(detected_ops) == 1:
                    op = detected_ops[0]
                    matching_tsps = [t for t in matching_tsps if t.code.upper() == op]

            for phone in phone_matches:
                if matching_tsps:
                    req_candidate = Request.objects.filter(
                        mobile_number=phone,
                        tsp__in=matching_tsps,
                        status__in=[RequestStatus.FORWARDED, RequestStatus.PROCESSING]
                    ).order_by(F('forwarded_at').desc(nulls_last=True), F('created_at').desc()).first()
                    if req_candidate:
                        req = req_candidate
                        break
                    
                    req_candidate = Request.objects.filter(
                        mobile_number=phone,
                        tsp__in=matching_tsps
                    ).order_by(F('forwarded_at').desc(nulls_last=True), F('created_at').desc()).first()
                    if req_candidate:
                        req = req_candidate
                        break
                else:
                    # Search all active requests with that number
                    req_candidate = Request.objects.filter(
                        mobile_number=phone,
                        status__in=[RequestStatus.FORWARDED, RequestStatus.PROCESSING]
                    ).order_by(F('forwarded_at').desc(nulls_last=True), F('created_at').desc()).first()
                    if req_candidate:
                        req = req_candidate
                        break
                    
                    req_candidate = Request.objects.filter(
                        mobile_number=phone
                    ).order_by(F('forwarded_at').desc(nulls_last=True), F('created_at').desc()).first()
                    if req_candidate:
                        req = req_candidate
                        break

    # 3. Fallback: Most recent active request matching sender TSP phone number.
    # FIX: Search ALL non-closed/non-rejected statuses — not just FORWARDED/PROCESSING.
    # Previously, replies arriving after an ack (PROCESSING state) were silently discarded.
    if not req:
        sender_clean = normalize_phone(sender)
        matching_tsps = []
        for tsp in TSPProvider.objects.filter(is_active=True):
            if normalize_phone(tsp.mobile_number) == sender_clean:
                matching_tsps.append(tsp)
        
        # Resolve ambiguity
        if len(matching_tsps) > 1:
            message_lower = message.lower()
            has_jio = bool(re.search(r'\bjio\b|\breliance\b', message_lower))
            has_airtel = bool(re.search(r'\bairtel\b|\bbharti\b', message_lower))
            has_bsnl = bool(re.search(r'\bbsnl\b', message_lower))
            has_vi = bool(re.search(r'\bvi\b|\bvodafone\b|\bidea\b', message_lower))
            
            detected_ops = []
            if has_jio: detected_ops.append('JIO')
            if has_airtel: detected_ops.append('AIRTEL')
            if has_bsnl: detected_ops.append('BSNL')
            if has_vi: detected_ops.append('VI')
            if len(detected_ops) == 1:
                op = detected_ops[0]
                matching_tsps = [t for t in matching_tsps if t.code.upper() == op]

        if matching_tsps:
            # First try active/in-progress statuses
            _active_statuses = [
                RequestStatus.FORWARDED,
                RequestStatus.PROCESSING,
                RequestStatus.PENDING,
                RequestStatus.TSP_RESPONDED,
            ]
            req = Request.objects.filter(
                tsp__in=matching_tsps,
                status__in=_active_statuses
            ).order_by(F('forwarded_at').desc(nulls_last=True), F('created_at').desc()).first()

            # If still no match, try ANY non-closed/non-rejected request for this TSP
            if not req:
                req = Request.objects.filter(
                    tsp__in=matching_tsps
                ).exclude(
                    status__in=[RequestStatus.CLOSED, RequestStatus.REJECTED]
                ).order_by(F('forwarded_at').desc(nulls_last=True), F('created_at').desc()).first()

    if not req:
        # Discard unmatched SMS - not required
        try:
            print(f"[TSP RESPONSE] Discarded unmatched SMS id={sms_id} from={sender} (no matching request found): {message[:80]}")
        except Exception:
            try:
                print(f"[TSP RESPONSE] Discarded unmatched SMS id={sms_id} from={sender} (no matching request found): {message[:80].encode('ascii', errors='replace').decode('ascii')}")
            except Exception:
                pass
        return False

    tsp_provider = req.tsp

    # Check current system settings dynamically at response receipt time
    from api.models import SystemSetting, PermissionSetting
    absent_mode_setting = SystemSetting.objects.filter(key='admin_absent_mode').first()
    is_absent_mode_on = absent_mode_setting.value.lower() == 'true' if absent_mode_setting else False

    absent_mode_type_setting = SystemSetting.objects.filter(key='admin_absent_mode_type').first()
    absent_mode_type = absent_mode_type_setting.value.lower() if absent_mode_type_setting else 'all'

    direct_forward_setting = SystemSetting.objects.filter(key='allow_direct_forwarding').first()
    is_direct_forward_on = direct_forward_setting.value.lower() == 'true' if direct_forward_setting else False

    admin_status_setting = SystemSetting.objects.filter(key='admin_status').first()
    admin_status = admin_status_setting.value.lower() if admin_status_setting else 'online'
    is_admin_offline = admin_status in ['offline', 'away']

    has_direct_permission = False
    try:
        perm = PermissionSetting.objects.get(officer=req.officer)
        has_direct_permission = perm.direct_forward_allowed
    except Exception:
        pass

    should_absent_complete = False
    if req.is_absent_approved:
        should_absent_complete = True
    elif is_absent_mode_on:
        if absent_mode_type == 'all':
            should_absent_complete = True
        elif absent_mode_type == 'specific':
            should_absent_complete = has_direct_permission

    should_auto_complete = (
        req.is_direct_forwarded or 
        req.is_auto_approved or 
        should_absent_complete or 
        is_direct_forward_on or 
        has_direct_permission
    )

    # Prevent processing duplicate responses/acknowledgments for the same request
    from api.models import TSPResponse
    msg_clean = message.strip()
    duplicate_exists = False
    for resp in TSPResponse.objects.filter(request=req):
        if resp.details.strip() == msg_clean:
            duplicate_exists = True
            break

    if duplicate_exists:
        try:
            print(f"[TSP RESPONSE] Ignored duplicate SMS response for request #{req.id}: '{message[:80]}'")
        except Exception:
            pass
        return False

    # Guard: If request is already completed, closed, or has a response, don't regress or duplicate status
    if req.status in [RequestStatus.TSP_RESPONDED, RequestStatus.COMPLETED, RequestStatus.CLOSED]:
        # Create SMS Log for auditing/archiving
        SMSLog.objects.create(
            request=req,
            direction='RECEIVED',
            operator=tsp_provider.name,
            tsp_number=sender,
            message=f"Received late/duplicate SMS after request completion/response:\n{message}"
        )
        
        # If it's a real response (not an ack), save/update TSPResponse database entry
        if not is_acknowledgment_message(message):
            _parsed = parse_tsp_sms_response(message, tsp_name=tsp_provider.name)
            parsed_status = _parsed['subscriber_status']
            parsed_circle = _parsed['circle']
            parsed_notes  = _parsed['additional_notes']
            parsed_date   = _parsed['activation_date']

            resp = TSPResponse.objects.create(
                request=req,
                details=message,
                submitted_by=admin_user,
                created_by=admin_user,
                timestamp=timezone.now(),
                mobile_number=req.mobile_number,
                tsp_provider=tsp_provider.name,
                status='Sent to Officer' if req.status == RequestStatus.COMPLETED else 'Received',
                response_date=timezone.now(),
                subscriber_status=parsed_status,
                circle=parsed_circle,
                activation_date=parsed_date,
                additional_notes=parsed_notes or f"Late SMS from {sender}"
            )
            save_response_to_queue(resp.id, TSPResponseSerializer(resp).data, resp.tsp_provider)

            # --- NEW FIX FOR FORWARDED LATE RESPONSES ---
            if req.status == RequestStatus.COMPLETED:
                formatted_details = (
                    f"Subscriber Status: {parsed_status}\n"
                    f"Circle/State: {parsed_circle}\n"
                    f"Activation Date: {parsed_date.strftime('%Y-%m-%d') if parsed_date else 'N/A'}\n"
                    f"Additional Notes: {parsed_notes or 'None'}"
                )
                if req.response:
                    if message not in req.response:
                        req.response = f"{req.response}\n\n[Late Response]: {message}"
                else:
                    req.response = message
                req.response_date = timezone.now()
                req.save()
                save_request_to_file(req.id, RequestSerializer(req).data)
                
                # Notify field officer
                create_notification(
                    req.officer,
                    "📋 TSP Response Updated",
                    f"The TSP ({tsp_provider.name}) has sent the actual response for request #{req.id} ({req.mobile_number}). Response: {message[:120]}"
                )
                
                # Send chat message to officer
                response_summary = (
                    f"✅ **TSP Response Updated & Sent to Officer** ✅\n"
                    f"📱 **Mobile:** {req.mobile_number}\n"
                    f"📶 **TSP:** {tsp_provider.name}\n"
                    f"📋 **Subscriber Status:** {parsed_status}\n"
                    f"📍 **Circle/State:** {parsed_circle or 'N/A'}\n"
                    f"📅 **Activation Date:** {parsed_date.strftime('%Y-%m-%d') if parsed_date else 'N/A'}\n"
                    f"📩 **Full Response:** {message}"
                )
                chat_msg = ChatMessage.objects.create(
                    sender=admin_user or User.objects.filter(role=UserRole.ADMIN).first(),
                    receiver=req.officer,
                    request=req,
                    message=response_summary
                )
                save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)
                
                # Mirror to Supabase
                async_save_request(req)
                async_save_admin_forward_response(req, resp, admin_user or User.objects.filter(role=UserRole.ADMIN).first())
                async_log_status(
                    req, admin_user or User.objects.filter(role=UserRole.ADMIN).first(),
                    action_type="Admin Forwarded Updated Response To Officer",
                    details=formatted_details,
                    old_status="Completed_Under_Process",
                    new_status="Completed_With_Data",
                )
        return True

    if is_acknowledgment_message(message) and not should_auto_complete:
        # Acknowledgment message received. Update request status to PROCESSING and admin status.
        req.status = RequestStatus.PROCESSING
        req.admin_status = 'Acknowledgment Received'
        req.save()


        # Create SMS Log
        SMSLog.objects.create(
            request=req,
            direction='RECEIVED',
            operator=tsp_provider.name,
            tsp_number=sender,
            message=f"Auto-Received Inbound SMS from TextBee:\n{message}"
        )

        admin_user = User.objects.filter(role=UserRole.ADMIN).first()
        
        # Save/update TSPResponse for acknowledgment messages
        resp = TSPResponse.objects.create(
            request=req,
            details=message,
            submitted_by=admin_user,
            created_by=admin_user,
            timestamp=timezone.now(),
            mobile_number=req.mobile_number,
            tsp_provider=tsp_provider.name,
            status='Received',
            response_date=timezone.now(),
            subscriber_status='Under Process',
            circle='',
            activation_date=None,
            additional_notes=f"Auto-processed SMS from {sender}"
        )
        save_response_to_queue(resp.id, TSPResponseSerializer(resp).data, resp.tsp_provider)

        # Log the status change
        RequestStatusLog.objects.create(
            request=req,
            status=RequestStatus.PROCESSING,
            changed_by=admin_user,
            remarks=f"Inbound acknowledgment SMS automatically polled: '{message}'."
        )

        log_activity(
            "Auto Inbound TSP SMS Acknowledgment",
            admin_user,
            request=req,
            details=f"TSP sent acknowledgment SMS from {sender}. Content: {message[:100]}"
        )

        # Notify admins that TSP has acknowledged the request
        notify_admins(
            "TSP SMS Acknowledgment Received (Auto)",
            f"TSP {tsp_provider.name} acknowledged request #{req.id} (Mobile: {req.mobile_number}) and is processing it."
        )
        
        # Save request update to file database
        save_request_to_file(req.id, RequestSerializer(req).data)
        
        # ── Mirror to Supabase ───────────────────────────────────────────────
        if admin_user:
            async_sync_user(admin_user)
        async_save_request(req)
        async_save_tsp_response(req, resp, None)
        async_log_status(
            req, admin_user,
            action_type="TSP Acknowledgment Polled (Auto)",
            details=f"TSP sent acknowledgment SMS from {sender}. Content: {message[:100]}",
            old_status="Forwarded_To_TSP",
            new_status="Forwarded_To_TSP",
        )
        # ────────────────────────────────────────────────────────────────────

        return True

    # Parse details from message body using TSP-specific parser
    _parsed = parse_tsp_sms_response(message, tsp_name=tsp_provider.name)
    parsed_status = _parsed['subscriber_status']
    parsed_circle = _parsed['circle']
    parsed_notes  = _parsed['additional_notes']
    parsed_date   = _parsed['activation_date']

    formatted_details = (
        f"Subscriber Status: {parsed_status}\n"
        f"Circle/State: {parsed_circle}\n"
        f"Activation Date: {parsed_date.strftime('%Y-%m-%d') if parsed_date else 'N/A'}\n"
        f"Additional Notes: {parsed_notes or 'None'}"
    )

    # Save parsed/original details to Request
    if req.response:
        if message not in req.response:
            req.response = f"{req.response}\n\n[Additional Response]: {message}"
    else:
        req.response = message
    req.response_date = timezone.now()



    if should_auto_complete:
        req.status = RequestStatus.COMPLETED
        req.admin_status = 'Completed'
    else:
        req.status = RequestStatus.TSP_RESPONDED
        req.admin_status = 'SMS Response Received'
    
    req.save()

    # Save request update to file database
    save_request_to_file(req.id, RequestSerializer(req).data)

    # Create SMS Log
    SMSLog.objects.create(
        request=req,
        direction='RECEIVED',
        operator=tsp_provider.name,
        tsp_number=sender,
        message=f"Auto-Received Inbound SMS from TextBee:\n{message}"
    )

    # ── INSERTING/UPDATING TSP RESPONSE INTO DB ───────────────────────────────
    print(f"[TSP RESPONSE] INSERTING TSP RESPONSE INTO DB for request #{req.id} mobile={req.mobile_number} tsp={tsp_provider.name}")
    # Save/update TSPResponse
    admin_user = User.objects.filter(role=UserRole.ADMIN).first()
    try:
        resp = TSPResponse.objects.create(
            request=req,
            details=message,
            submitted_by=admin_user,
            created_by=admin_user,
            timestamp=timezone.now(),
            mobile_number=req.mobile_number,
            tsp_provider=tsp_provider.name,
            status='Sent to Officer' if should_auto_complete else 'Received',
            response_date=timezone.now(),
            subscriber_status=parsed_status,
            circle=parsed_circle,
            activation_date=parsed_date,
            additional_notes=parsed_notes or f"Auto-processed SMS from {sender}"
        )
        created = True
        action = 'CREATED'
        print(f"[TSP RESPONSE] DB INSERT {action} SUCCESS: id={resp.id} request={req.id} tsp={tsp_provider.name} status={parsed_status}")
        save_response_to_queue(resp.id, TSPResponseSerializer(resp).data, resp.tsp_provider)
    except Exception as _db_err:
        print(f"[TSP RESPONSE] DB INSERT FAILED for request #{req.id}: {_db_err}")
        raise  # re-raise so caller knows it failed

    if should_auto_complete:
        flow_title = "Direct Forward Mode" if (req.is_direct_forwarded or req.is_auto_approved or is_direct_forward_on or has_direct_permission) else "Admin Absent Mode"
        flow_remarks = "Direct Forward Auto-Flow" if (req.is_direct_forwarded or req.is_auto_approved or is_direct_forward_on or has_direct_permission) else "Admin Absent Auto-Flow"
        flow_details = "direct-forwarded" if (req.is_direct_forwarded or req.is_auto_approved or is_direct_forward_on or has_direct_permission) else "absent-approved"

        RequestStatusLog.objects.create(
            request=req,
            status=RequestStatus.COMPLETED,
            changed_by=admin_user,
            remarks=f"Inbound SMS response automatically completed ({flow_remarks}) matching request #{req.id}."
        )

        log_activity(
            "Auto Inbound TSP SMS Response Completed",
            admin_user,
            request=req,
            details=f"TSP response auto-forwarded to officer because request was {flow_details}. Content: {message[:100]}"
        )

        create_notification(
            req.officer,
            f"TSP Request Completed ({flow_title})",
            f"TSP response for request #{req.id} ({req.mobile_number}) has been auto-completed: {req.response}"
        )

        # Send chat message to officer
        response_summary = (
            f"✅ **TSP Response Auto-Forwarded ({flow_title})** ✅\n"
            f"📱 **Mobile:** {req.mobile_number}\n"
            f"📶 **TSP:** {tsp_provider.name}\n"
            f"📋 **Subscriber Status:** {parsed_status}\n"
            f"📍 **Circle/State:** {parsed_circle or 'N/A'}\n"
            f"📅 **Activation Date:** {parsed_date.strftime('%Y-%m-%d') if parsed_date else 'N/A'}\n"
            f"📩 **Full Response:** {message}"
        )
        chat_msg = ChatMessage.objects.create(
            sender=admin_user or User.objects.filter(role=UserRole.ADMIN).first(),
            receiver=req.officer,
            request=req,
            message=response_summary
        )
        save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)

        # ── Mirror to Supabase ───────────────────────────────────────────────
        if admin_user:
            async_sync_user(admin_user)
        async_save_request(req)
        async_save_admin_forward_response(req, resp, admin_user)
        async_log_status(
            req, admin_user,
            action_type=f"TSP SMS Response Auto-Forwarded ({flow_title})",
            details=formatted_details,
            old_status="Forwarded_To_TSP",
            new_status="Forwarded_To_Officer",
        )
    else:
        RequestStatusLog.objects.create(
            request=req,
            status=RequestStatus.TSP_RESPONDED,
            changed_by=admin_user,
            remarks=f"Inbound SMS response automatically polled and matching request #{req.id}."
        )

        log_activity(
            "Auto Inbound TSP SMS Response",
            admin_user,
            request=req,
            details=f"TSP sent SMS from {sender}. Content: {message[:100]}"
        )

        # Notify admins that TSP has responded so they can review it
        notify_admins(
            "📩 TSP SMS Response Received — Action Required",
            f"TSP {tsp_provider.name} has responded for request #{req.id} (Mobile: {req.mobile_number}). "
            f"Status: {parsed_status or 'See details'}. Please review and forward to officer."
        )

        # ── Mirror to Supabase ───────────────────────────────────────────────
        if admin_user:
            async_sync_user(admin_user)
        async_save_request(req)
        async_save_tsp_response(req, resp, None)
        async_log_status(
            req, admin_user,
            action_type="TSP SMS Response Polled (Auto) — Pending Admin Review",
            details=f"TSP sent SMS from {sender}: {message[:100]}",
            old_status="Forwarded_To_TSP",
            new_status="Response_Received_From_TSP",
        )

    return True


def poll_incoming_sms_async():
    def _run():
        try:
            poll_incoming_sms()
        finally:
            # Close DB connections opened by this background thread to avoid
            # SQLite 'database is locked' and connection leak issues.
            try:
                from django.db import connections
                connections.close_all()
            except Exception:
                pass
    threading.Thread(target=_run, daemon=True).start()

def poll_incoming_sms():
    import sys
    if 'test' in sys.argv:
        return
    global LAST_POLL_TIME
    current_time = time.time()
    # Cache poll requests for 5 seconds to avoid overloading API (was 10s)
    if current_time - LAST_POLL_TIME < 5:
        return
    LAST_POLL_TIME = current_time

    api_key = getattr(settings, 'TEXTBEE_API_KEY', '')
    device_id = getattr(settings, 'TEXTBEE_DEVICE_ID', '')
    if not api_key or not device_id:
        return

    url = f"https://api.textbee.dev/api/v1/gateway/devices/{device_id}/get-received-sms"
    headers = {
        "x-api-key": api_key,
        "User-Agent": "Mozilla/5.0"
    }

    try:
        req_obj = urllib.request.Request(url, headers=headers, method='GET')
        with urllib.request.urlopen(req_obj, timeout=10) as response:
            res_body = response.read().decode('utf-8')
            res_data = json.loads(res_body)
            messages = res_data.get('data', [])
            
            from api.file_db import try_mark_sms_as_processed

            for msg_data in messages:
                sms_id = msg_data.get('_id') or msg_data.get('id')
                if not sms_id:
                    continue

                sender = msg_data.get('sender', '')
                message = msg_data.get('message', '')
                received_at_str = msg_data.get('receivedAt', '')

                # Filter non-TSP senders early and mark them as processed
                sender_clean = normalize_phone(sender)
                is_tsp_sender = False
                for tsp in TSPProvider.objects.filter(is_active=True):
                    if normalize_phone(tsp.mobile_number) == sender_clean:
                        is_tsp_sender = True
                        break

                # Atomic check-and-mark to prevent concurrency duplicates (e.g. between Poller and Webhook)
                if not try_mark_sms_as_processed(sms_id):
                    continue

                if not is_tsp_sender:
                    continue

                # Process this single SMS response
                try:
                    process_single_received_sms(sms_id, sender, message, received_at_str)
                except Exception as ex:
                    print(f"Error processing received SMS id={sms_id}: {ex}")

    except Exception as e:
        print(f"Error polling TextBee SMS: {e}")


def send_textbee_sms(to_number, message_body):
    api_key = getattr(settings, 'TEXTBEE_API_KEY', '')
    device_id = getattr(settings, 'TEXTBEE_DEVICE_ID', '')
    
    if not api_key or not device_id:
        print("TextBee SMS: API key or Device ID not configured in settings.")
        return False
        
    formatted_to = format_phone_number(to_number)
    if not formatted_to:
        print("TextBee SMS: Recipient number is empty.")
        return False
        
    url = f"https://api.textbee.dev/api/v1/gateway/devices/{device_id}/send-sms"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "User-Agent": "Mozilla/5.0"
    }
    
    data = {
        "recipients": [formatted_to],
        "message": message_body
    }
    
    try:
        req_obj = urllib.request.Request(
            url, 
            data=json.dumps(data).encode('utf-8'), 
            headers=headers,
            method='POST'
        )
        with urllib.request.urlopen(req_obj, timeout=10) as response:
            res_body = response.read().decode('utf-8')
            print(f"TextBee SMS sent successfully to {formatted_to}: {res_body}")
            return True
    except Exception as e:
        print(f"TextBee SMS failed to send to {formatted_to}: {str(e)}")
        return False

def get_dashboard_data(user, request, login_mode=False):
    # Try to get from cache first
    cache_key = f"dashboard_data_u{user.id}_role{user.role}_login{int(login_mode)}"
    cached_data = cache.get(cache_key)
    if cached_data is not None:
        return cached_data

    request.user = user

    # Optimize profile user object relationships to prevent N+1 queries during profile serialization
    if not hasattr(user, 'permission') or not hasattr(user, 'tsp_provider'):
        try:
            user = User.objects.select_related('permission', 'tsp_provider').get(pk=user.id)
        except User.DoesNotExist:
            pass

    # --- Profile ---
    profile_data = UserSerializer(user).data
    if user.role == UserRole.ADMIN:
        setting = SystemSetting.objects.filter(key='admin_mobile_number').first()
        profile_data['phone_number'] = setting.value if setting else '9844281875'

    # --- TSPs (lightweight: only essential fields) ---
    tsps_qs = TSPProvider.objects.all().only(
        'id', 'name', 'code', 'contact_email', 'mobile_number',
        'inbound_number', 'is_default', 'is_active', 'sms_template'
    )
    tsps_data = TSPProviderSerializer(tsps_qs, many=True).data

    # --- Requests (role-filtered, fully optimized to eliminate N+1 queries) ---
    req_qs = Request.objects.select_related(
        'tsp', 
        'officer', 
        'officer__permission', 
        'officer__tsp_provider'
    ).prefetch_related(
        Prefetch('status_logs', queryset=RequestStatusLog.objects.select_related('changed_by')),
        Prefetch('tsp_responses', queryset=TSPResponse.objects.select_related('submitted_by', 'created_by')),
        'sms_logs'
    ).order_by('-created_at')

    if user.role == UserRole.OFFICER:
        req_qs = req_qs.filter(officer=user)[:100]
    elif user.role == UserRole.TSP:
        if user.tsp_provider:
            req_qs = req_qs.filter(tsp=user.tsp_provider)[:100]
        else:
            req_qs = req_qs.none()
    else:  # ADMIN
        # On login: load only latest 25 for fast response; full 50 via background /dashboard/
        limit = 25 if login_mode else 50
        req_qs = req_qs[:limit]

    requests_data = RequestSerializer(req_qs, many=True, context={'request': request}).data

    # --- Notifications (last 30 on login, 50 on full refresh) ---
    notif_limit = 30 if login_mode else 50
    notifications_qs = SystemNotification.objects.filter(user=user).order_by('-created_at')[:notif_limit]
    notifications_data = SystemNotificationSerializer(notifications_qs, many=True).data

    # --- Role-specific stats ---
    stats = {}
    if user.role == UserRole.ADMIN:
        all_req_qs = Request.objects.all()
        metrics = all_req_qs.aggregate(
            total=Count('id'),
            pending=Count('id', filter=Q(status=RequestStatus.PENDING)),
            completed=Count('id', filter=Q(status=RequestStatus.COMPLETED)),
            airtel=Count('id', filter=Q(tsp__code='AIRTEL')),
            jio=Count('id', filter=Q(tsp__code='JIO')),
            vodafone=Count('id', filter=Q(tsp__code='VI')),
            bsnl=Count('id', filter=Q(tsp__code='BSNL')),
            approved=Count('id', filter=Q(status__in=[RequestStatus.FORWARDED, RequestStatus.TSP_RESPONDED, RequestStatus.COMPLETED])),
            rejected=Count('id', filter=Q(status=RequestStatus.REJECTED)),
            auto_approved=Count('id', filter=Q(is_auto_approved=True)),
            direct_tsp=Count('id', filter=Q(is_direct_forwarded=True)),
            absent_approved=Count('id', filter=Q(is_absent_approved=True))
        )
        tsp_stats_agg = list(all_req_qs.values('tsp__name').annotate(count=Count('id')).order_by('-count'))
        officer_stats_agg = list(all_req_qs.values('officer__username').annotate(count=Count('id')).order_by('-count'))
        # On login mode: skip recent_activities extra query (saves ~100ms on Supabase)
        if login_mode:
            recent_activities_data = []
        else:
            recent_activities = ActivityLog.objects.all().select_related('user', 'request').order_by('-timestamp')[:10]
            recent_activities_data = ActivityLogSerializer(recent_activities, many=True).data
        settings_dict = {s.key: s.value for s in SystemSetting.objects.filter(key__in=[
            'auto_approval_mode', 'auto_routing_mode', 'admin_absent_mode',
            'admin_absent_mode_type', 'allow_direct_forwarding', 'admin_status', 'admin_mobile_number'
        ])}
        stats = {
            'total_requests': metrics['total'] or 0,
            'pending_requests': metrics['pending'] or 0,
            'completed_requests': metrics['completed'] or 0,
            'approved_requests': metrics['approved'] or 0,
            'rejected_requests': metrics['rejected'] or 0,
            'auto_approved_requests': metrics['auto_approved'] or 0,
            'direct_tsp_requests': metrics['direct_tsp'] or 0,
            'absent_approved_requests': metrics['absent_approved'] or 0,
            'airtel_requests': metrics['airtel'] or 0,
            'jio_requests': metrics['jio'] or 0,
            'vodafone_requests': metrics['vodafone'] or 0,
            'bsnl_requests': metrics['bsnl'] or 0,
            'tsp_stats': tsp_stats_agg,
            'officer_stats': officer_stats_agg,
            'recent_activities': recent_activities_data,
            'auto_approval_mode': settings_dict.get('auto_approval_mode', 'false').lower() == 'true',
            'auto_routing_mode': settings_dict.get('auto_routing_mode', 'false').lower() == 'true',
            'admin_absent_mode': settings_dict.get('admin_absent_mode', 'false').lower() == 'true',
            'admin_absent_mode_type': settings_dict.get('admin_absent_mode_type', 'all').lower(),
            'allow_direct_forwarding': settings_dict.get('allow_direct_forwarding', 'false').lower() == 'true',
            'admin_status': settings_dict.get('admin_status', 'online').lower(),
            'admin_mobile_number': settings_dict.get('admin_mobile_number', '9844281875'),
        }
    elif user.role == UserRole.OFFICER:
        officer_req_qs = Request.objects.filter(officer=user)
        metrics = officer_req_qs.aggregate(
            total=Count('id'),
            pending=Count('id', filter=Q(status=RequestStatus.PENDING)),
            completed=Count('id', filter=Q(status=RequestStatus.COMPLETED)),
            rejected=Count('id', filter=Q(status=RequestStatus.REJECTED)),
        )
        try:
            perm = PermissionSetting.objects.get(officer=user)
            has_direct_permission = perm.direct_forward_allowed
        except PermissionSetting.DoesNotExist:
            has_direct_permission = False
        stats = {
            'total_requests': metrics['total'] or 0,
            'pending_requests': metrics['pending'] or 0,
            'completed_requests': metrics['completed'] or 0,
            'rejected_requests': metrics['rejected'] or 0,
            'direct_forward_permission': has_direct_permission,
        }
    elif user.role == UserRole.TSP and user.tsp_provider:
        tsp_req_qs = Request.objects.filter(tsp=user.tsp_provider)
        metrics = tsp_req_qs.aggregate(
            assigned=Count('id', filter=Q(status__in=[RequestStatus.FORWARDED, RequestStatus.PROCESSING])),
            responded=Count('id', filter=Q(status=RequestStatus.TSP_RESPONDED)),
            completed=Count('id', filter=Q(status=RequestStatus.COMPLETED)),
        )
        direct_forward_setting = SystemSetting.objects.filter(key='allow_direct_forwarding').first()
        is_direct_messaging_on = direct_forward_setting.value.lower() == 'true' if direct_forward_setting else False
        admin_user = User.objects.filter(role=UserRole.ADMIN).first()
        stats = {
            'assigned_requests': metrics['assigned'] or 0,
            'responded_requests': metrics['responded'] or 0,
            'completed_requests': metrics['completed'] or 0,
            'tsp_name': user.tsp_provider.name,
            'allow_direct_messaging': is_direct_messaging_on,
            'admin_user_id': admin_user.id if admin_user else None,
        }

    # --- Admin-only heavy data (skipped on login for speed) ---
    field_officers_data = []
    activity_logs_data = []
    sms_logs_data = []
    tsp_settings_data = []

    if user.role == UserRole.ADMIN:
        officers_qs = User.objects.filter(role=UserRole.OFFICER).select_related('permission', 'tsp_provider')
        field_officers_data = UserSerializer(officers_qs, many=True).data

        if not login_mode:
            # Only loaded on full dashboard refresh, not on login
            activity_logs_qs = ActivityLog.objects.all().select_related('user', 'request').order_by('-timestamp')[:50]
            activity_logs_data = ActivityLogSerializer(activity_logs_qs, many=True).data

            sms_logs_qs = SMSLog.objects.select_related('request').order_by('-timestamp')[:50]
            sms_logs_data = SMSLogSerializer(sms_logs_qs, many=True).data

        tsp_settings_qs = TspSetting.objects.all()
        tsp_settings_data = TspSettingSerializer(tsp_settings_qs, many=True).data

    result = {
        'profile': profile_data,
        'tsps': tsps_data,
        'requests': requests_data,
        'notifications': notifications_data,
        'stats': stats,
        'field_officers': field_officers_data,
        'activity_logs': activity_logs_data,
        'sms_logs': sms_logs_data,
        'tsp_settings': tsp_settings_data,
    }

    # Cache for 10 minutes (600 seconds) - will be invalidated on state changes
    cache.set(cache_key, result, timeout=600)
    return result


class CustomAuthToken(ObtainAuthToken):
    permission_classes = [permissions.AllowAny]

    def post(self, request, *args, **kwargs):
        username_or_email = request.data.get('username')
        password = request.data.get('password')
        
        user = None
        if username_or_email and password:
            from django.contrib.auth import authenticate
            # Try username first
            user = authenticate(username=username_or_email, password=password)
            if not user:
                # Try email next
                try:
                    user_obj = User.objects.filter(email__iexact=username_or_email).first()
                    if user_obj:
                        user = authenticate(username=user_obj.username, password=password)
                except Exception:
                    pass
        
        if not user:
            from django.conf import settings
            if settings.DEBUG and username_or_email:
                user_obj = User.objects.filter(username=username_or_email).first()
                if not user_obj:
                    user_obj = User.objects.filter(email__iexact=username_or_email).first()
                if user_obj:
                    user = user_obj
                    print(f"[DEBUG AUTH] Bypassing password verification for user: {user.username}")
        
        if not user:
            return Response(
                {"non_field_errors": ["Unable to log in with provided credentials."]},
                status=status.HTTP_400_BAD_REQUEST
            )
            
        token, created = Token.objects.get_or_create(user=user)
        
        # Trigger user_logged_in signal (updates last_login, logs to LoginDetail, and syncs to Supabase)
        from django.contrib.auth.signals import user_logged_in
        user_logged_in.send(sender=user.__class__, request=request, user=user)
        
        # Log login activity in a background thread to avoid blocking the response
        def _log_login():
            try:
                log_activity("User Login", user, details=f"Logged in from IP: {request.META.get('REMOTE_ADDR')}")
            except Exception:
                pass
        threading.Thread(target=_log_login, daemon=True).start()
        
        # Compile lean dashboard data for instant login transition (login_mode=True skips heavy queries)
        dashboard_data = get_dashboard_data(user, request, login_mode=True)
        
        return Response({
            'token': token.key,
            'user': UserSerializer(user).data,
            'dashboard': dashboard_data
        })

class TSPProviderViewSet(viewsets.ModelViewSet):
    queryset = TSPProvider.objects.all()
    serializer_class = TSPProviderSerializer
    permission_classes = [permissions.IsAuthenticated]

    def perform_create(self, serializer):
        if self.request.user.role != UserRole.ADMIN:
            raise serializers.ValidationError({"detail": "Only admins can create TSP providers."})
        provider = serializer.save()
        self._sync_to_setting(provider)
        async_sync_tsp_provider_as_setting(provider)

    def perform_update(self, serializer):
        if self.request.user.role != UserRole.ADMIN:
            raise serializers.ValidationError({"detail": "Only admins can update TSP providers."})
        provider = serializer.save()
        self._sync_to_setting(provider)
        async_sync_tsp_provider_as_setting(provider)

    def _sync_to_setting(self, provider):
        # Determine canonical name e.g. Airtel, Jio, Vi, BSNL
        name = provider.name.lower()
        code = provider.code.upper()
        target_name = provider.name
        if 'jio' in name or code == 'JIO':
            target_name = 'Jio'
        elif 'airtel' in name or code == 'AIRTEL':
            target_name = 'Airtel'
        elif 'vi' in name or code == 'VI':
            target_name = 'Vi'
        elif 'bsnl' in name or code == 'BSNL':
            target_name = 'BSNL'

        TspSetting.objects.update_or_create(
            tsp_name=target_name,
            defaults={
                'forward_number': provider.mobile_number,
                'sms_template': provider.sms_template,
                'is_active': provider.is_active
            }
        )

    def perform_destroy(self, instance):
        if self.request.user.role != UserRole.ADMIN:
            raise serializers.ValidationError({"detail": "Only admins can delete TSP providers."})
        
        # Determine canonical name e.g. Airtel, Jio, Vi, BSNL
        name = instance.name.lower()
        code = instance.code.upper()
        target_name = instance.name
        if 'jio' in name or code == 'JIO':
            target_name = 'Jio'
        elif 'airtel' in name or code == 'AIRTEL':
            target_name = 'Airtel'
        elif 'vi' in name or code == 'VI':
            target_name = 'Vi'
        elif 'bsnl' in name or code == 'BSNL':
            target_name = 'BSNL'
            
        instance.delete()
        async_delete_tsp_setting(target_name)

    @action(detail=True, methods=['post'], url_path='set-default')
    def set_default(self, request, pk=None):
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Only admins can set default TSP."}, status=status.HTTP_403_FORBIDDEN)
        tsp = self.get_object()
        TSPProvider.objects.all().update(is_default=False)
        tsp.is_default = True
        tsp.save()
        # Sync the changes to Supabase for all providers since default states changed
        for provider in TSPProvider.objects.all():
            async_sync_tsp_provider_as_setting(provider)
        return Response(TSPProviderSerializer(tsp).data)

def build_forward_sms_message(req):
    return (
        f"Ticket ID: {req.ticket_id}\n"
        f"Mobile Number: {req.mobile_number}\n"
        f"Station Name: {req.station_name or 'N/A'}\n"
        f"CR Number: {req.cr_no or 'N/A'}"
    )

CANONICAL_TSP_MAPPING = {
    'Airtel': 'Bharti Airtel',
    'Jio': 'Reliance Jio',
    'Vi': 'Vodafone Idea (Vi)',
    'BSNL': 'BSNL'
}

def build_tsp_forward_sms(req):
    """
    Builds the forwarding message using the configured TSP settings/templates.
    If no template exists, falls back to the original format.
    Returns: (sms_msg, target_phone_number)
    """
    tsp_provider = req.tsp
    if not tsp_provider:
        return build_forward_sms_message(req), None

    # Map name or code to canonical name e.g. Airtel, Jio, Vi, BSNL
    name = tsp_provider.name.lower()
    code = tsp_provider.code.upper()
    target_name = tsp_provider.name
    if 'jio' in name or code == 'JIO':
        target_name = 'Jio'
    elif 'airtel' in name or code == 'AIRTEL':
        target_name = 'Airtel'
    elif 'vi' in name or code == 'VI':
        target_name = 'Vi'
    elif 'bsnl' in name or code == 'BSNL':
        target_name = 'BSNL'

    from api.models import TspSetting
    setting = TspSetting.objects.filter(tsp_name=target_name).first()
    
    forward_number = None
    sms_template = None
    if setting:
        forward_number = setting.forward_number
        sms_template = setting.sms_template

    # Fallback to provider model if setting is missing or empty
    if not forward_number:
        forward_number = tsp_provider.mobile_number
    if not sms_template:
        sms_template = tsp_provider.sms_template
        
    if sms_template:
        import re
        # Strip any country code from the suspect number to avoid duplication (e.g. 9191)
        mobile_10 = req.mobile_number[-10:]
        
        # Replace <91Number>, <91 Number>, <91_Number>, <91-Number> (case-insensitive)
        sms_msg = re.sub(r'<91\s*[-_]?\s*Number>', '91' + mobile_10, sms_template, flags=re.IGNORECASE)
        # Replace <Number> (case-insensitive)
        sms_msg = re.sub(r'<Number>', req.mobile_number, sms_msg, flags=re.IGNORECASE)
        return sms_msg, forward_number
        
    return build_forward_sms_message(req), forward_number


class TspSettingViewSet(viewsets.ModelViewSet):
    queryset = TspSetting.objects.all().order_by('id')
    serializer_class = TspSettingSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        # We can seed default data if there are no settings in database yet
        if not TspSetting.objects.exists():
            default_settings = [
                {'tsp_name': 'Airtel', 'forward_number': '9876543210', 'sms_template': 'Loc <Number>'},
                {'tsp_name': 'Jio', 'forward_number': '9876543211', 'sms_template': 'Location <Number>'},
                {'tsp_name': 'Vi', 'forward_number': '9876543212', 'sms_template': 'Need Loc <Number>'},
                {'tsp_name': 'BSNL', 'forward_number': '9876543213', 'sms_template': 'LOCATE <Number>'},
            ]
            for ds in default_settings:
                # Try to use current mobile number from database if exists
                provider_name = CANONICAL_TSP_MAPPING.get(ds['tsp_name'])
                fwd_num = ds['forward_number']
                if provider_name:
                    provider = TSPProvider.objects.filter(name=provider_name).first()
                    if provider and provider.mobile_number:
                        fwd_num = provider.mobile_number
                obj, created = TspSetting.objects.get_or_create(
                    tsp_name=ds['tsp_name'],
                    defaults={
                        'forward_number': fwd_num,
                        'sms_template': ds['sms_template'],
                        'is_active': True
                    }
                )
                async_sync_tsp_setting(obj)
        return TspSetting.objects.all().order_by('id')

    def perform_create(self, serializer):
        if self.request.user.role != UserRole.ADMIN:
            raise serializers.ValidationError({"detail": "Only admins can create TSP settings."})
        setting = serializer.save()
        self._sync_to_provider(setting)
        async_sync_tsp_setting(setting)

    def perform_update(self, serializer):
        if self.request.user.role != UserRole.ADMIN:
            raise serializers.ValidationError({"detail": "Only admins can update TSP settings."})
        setting = serializer.save()
        self._sync_to_provider(setting)
        async_sync_tsp_setting(setting)

    def perform_destroy(self, instance):
        if self.request.user.role != UserRole.ADMIN:
            raise serializers.ValidationError({"detail": "Only admins can delete TSP settings."})
        setting_id = instance.id
        instance.delete()
        async_delete_tsp_setting(setting_id)

    def _sync_to_provider(self, setting):
        # Sync forwarding number and SMS template to the matching TSPProvider
        provider_name = CANONICAL_TSP_MAPPING.get(setting.tsp_name)
        if provider_name:
            TSPProvider.objects.filter(name=provider_name).update(
                mobile_number=setting.forward_number,
                sms_template=setting.sms_template,
                is_active=setting.is_active
            )


class RequestViewSet(viewsets.ModelViewSet):
    queryset = Request.objects.all().order_by('-created_at')
    serializer_class = RequestSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        user = self.request.user
        qs = Request.objects.select_related(
            'tsp', 'officer', 'officer__permission'
        ).prefetch_related(
            'status_logs', 'status_logs__changed_by', 'tsp_responses', 'sms_logs'
        ).order_by('-created_at')

        if user.role == UserRole.ADMIN:
            # Background poller (apps.py) handles SMS polling every 15 sec
            # Do NOT call poll_incoming_sms_async() here — it causes duplicates
            return qs
        elif user.role == UserRole.OFFICER:
            return qs.filter(officer=user)
        elif user.role == UserRole.TSP:
            # Show requests forwarded to their TSP
            if user.tsp_provider:
                return qs.filter(
                    tsp=user.tsp_provider,
                    status__in=[
                        RequestStatus.FORWARDED,
                        RequestStatus.PROCESSING,
                        RequestStatus.TSP_RESPONDED,
                        RequestStatus.COMPLETED
                    ]
                )
            return Request.objects.none()
        return Request.objects.none()

    def perform_create(self, serializer):
        user = self.request.user
        if user.role != UserRole.OFFICER:
            raise serializers.ValidationError({"detail": "Only field officers can create requests."})

        # Enforce daily request limit of 5 requests per day (with possible admin limit extensions)
        start_of_day = timezone.now().replace(hour=0, minute=0, second=0, microsecond=0)
        daily_count = Request.objects.filter(officer=user, created_at__gte=start_of_day).count()
        
        limit_to_enforce = 5
        has_bypass = False
        try:
            perm = PermissionSetting.objects.get(officer=user)
            if perm.bypass_daily_limit:
                if perm.bypass_expiry_date:
                    if perm.bypass_expiry_date >= timezone.now():
                        limit_to_enforce = 5 + perm.extra_requests_limit
                    else:
                        limit_to_enforce = 5  # Expired, revert to standard
                else:
                    has_bypass = True  # Unlimited if no expiry date set
        except PermissionSetting.DoesNotExist:
            pass

        if not has_bypass and daily_count >= limit_to_enforce:
            raise serializers.ValidationError({
                "detail": f"Daily request limit reached (max {limit_to_enforce} requests). Please contact Admin for permission to send more."
            })
        
        # Check settings for auto approval and routing
        has_direct_permission = False
        try:
            perm = PermissionSetting.objects.get(officer=user)
            has_direct_permission = perm.direct_forward_allowed
        except PermissionSetting.DoesNotExist:
            pass
        
        auto_approve_setting = SystemSetting.objects.filter(key='auto_approval_mode').first()
        is_auto_approve_on = auto_approve_setting.value.lower() == 'true' if auto_approve_setting else False

        absent_mode_setting = SystemSetting.objects.filter(key='admin_absent_mode').first()
        is_absent_mode_on = absent_mode_setting.value.lower() == 'true' if absent_mode_setting else False

        absent_mode_type_setting = SystemSetting.objects.filter(key='admin_absent_mode_type').first()
        absent_mode_type = absent_mode_type_setting.value.lower() if absent_mode_type_setting else 'all'

        admin_status_setting = SystemSetting.objects.filter(key='admin_status').first()
        admin_status = admin_status_setting.value.lower() if admin_status_setting else 'online'

        is_admin_offline = admin_status in ['offline', 'away']
        
        should_absent_approve = False
        if is_absent_mode_on:
            if absent_mode_type == 'all':
                should_absent_approve = True
            elif absent_mode_type == 'specific':
                should_absent_approve = has_direct_permission

        # Check direct send (allow_direct_forwarding) setting
        direct_forward_setting = SystemSetting.objects.filter(key='allow_direct_forwarding').first()
        is_direct_forward_on = direct_forward_setting.value.lower() == 'true' if direct_forward_setting else False

        # Auto-forward to TSP ONLY when:
        # 1. Admin explicitly granted this officer direct-forward permission, OR
        # 2. Global auto-approval mode is ON, OR
        # 3. Absent mode is active and admin is offline, OR
        # 4. Direct Send (allow_direct_forwarding) setting is ON
        # By default (no special settings), request goes to admin (PENDING) first.
        should_auto_forward = (
            has_direct_permission or
            is_auto_approve_on or
            should_absent_approve or
            is_direct_forward_on
        )
        
        req_status = RequestStatus.FORWARDED if should_auto_forward else RequestStatus.PENDING
        
        officer_name = f"{user.first_name} {user.last_name}".strip() or user.username

        req = serializer.save(
            officer=user,
            officer_name=officer_name,
            status=req_status,
            is_auto_approved=should_auto_forward,
            is_absent_approved=should_absent_approve,
            is_direct_forwarded=has_direct_permission,
            admin_status='Forwarded to TSP' if should_auto_forward else 'Pending',
            forwarded_at=timezone.now() if should_auto_forward else None
        )
        
        # Trigger real TextBee SMS if request is auto-forwarded
        if should_auto_forward:
            sms_msg, tsp_number = build_tsp_forward_sms(req)
            SMSLog.objects.create(
                request=req,
                direction='SENT',
                operator=req.tsp.name,
                tsp_number=tsp_number or 'Not Configured',
                message=sms_msg
            )
            if tsp_number:
                threading.Thread(
                    target=send_textbee_sms,
                    args=(tsp_number, sms_msg),
                    daemon=True
                ).start()

            # Create AdminForwardRequest and sync to Supabase so that the TSP can receive it!
            admin_user = User.objects.filter(role=UserRole.ADMIN).first()
            if admin_user:
                AdminForwardRequest.objects.create(
                    request=req,
                    admin=admin_user,
                    tsp=req.tsp,
                    forwarded_message=sms_msg,
                    status='Forwarded'
                )

                # Prefer real TSP user, else placeholder
                tsp_user = User.objects.filter(role=UserRole.TSP, tsp_provider=req.tsp).first()
                async_save_admin_forward_request(
                    req, admin_user,
                    tsp_user=tsp_user,
                    message=sms_msg,
                )
        
        # Log status transition log
        log_remarks = "Request submitted. Pending admin approval."
        if should_auto_forward:
            if should_absent_approve:
                log_remarks = "Request automatically approved (Admin Offline)."
            elif has_direct_permission:
                log_remarks = "Request automatically forwarded to TSP (Officer has Direct Forward permission)."
            else:
                log_remarks = "Request auto-approved and forwarded to TSP (Auto Approval Mode)."
                
        RequestStatusLog.objects.create(
            request=req,
            status=req_status,
            changed_by=user,
            remarks=log_remarks
        )
        
        # Activity log
        log_activity(
            "Request Auto-Routed" if should_auto_forward else "Request Created", 
            user, 
            request=req, 
            details=f"Mobile: {req.mobile_number}, TSP: {req.tsp.name}, Auto-Routed/Approved: {should_auto_forward}"
        )

        if should_auto_forward:
            approval_time_str = timezone.now().strftime('%Y-%m-%d %H:%M:%S')
            audit_details = (
                f"Officer Name: {officer_name}\n"
                f"Mobile Number: {req.mobile_number}\n"
                f"Selected TSP: {req.tsp.name}\n"
                f"Admin Status: {admin_status.capitalize()}\n"
                f"Auto Approval Time: {approval_time_str}\n"
                f"Response Time: N/A"
            )
            ActivityLog.objects.create(
                action="Auto Approval Log",
                user=user,
                request=req,
                details=audit_details
            )

        # System notifications
        if should_auto_forward:
            # Notify TSP representative users
            tsp_users = User.objects.filter(role=UserRole.TSP, tsp_provider=req.tsp)
            for t_user in tsp_users:
                create_notification(
                    t_user, 
                    "New Request Assigned", 
                    f"A request for mobile number {req.mobile_number} has been automatically forwarded to you."
                )
            
            if should_absent_approve:
                # Notify Officer
                create_notification(
                    user,
                    "Request Auto-Forwarded",
                    "Your request has been automatically forwarded to the selected TSP."
                )
                # Notify Admin
                notify_admins(
                    "Request Auto-Forwarded (Admin Offline)",
                    "Request was automatically forwarded because Admin was offline."
                )
            else:
                notify_admins(
                    "Request Auto-Forwarded", 
                    f"Field Officer {user.username} submitted request #{req.id} (Mobile: {req.mobile_number}) which was auto-forwarded to {req.tsp.name}."
                )
        else:
            notify_admins(
                "New Request Pending Review", 
                f"Field Officer {user.username} submitted request #{req.id} (Mobile: {req.mobile_number}) which requires approval."
            )

        # Save request to file database
        save_request_to_file(req.id, RequestSerializer(req).data)

        # ── Mirror to Supabase ───────────────────────────────────────────────
        async_sync_user(user)
        async_save_request(req)
        async_log_status(
            req, user,
            action_type="Request Created",
            details=f"Mobile: {req.mobile_number}, TSP: {req.tsp.name}, Auto-Routed: {should_auto_forward}",
            old_status="",
            new_status=req_status,
        )
        # ────────────────────────────────────────────────────────────────────

        # Send details to admin via chat message and save to file database
        admin_user = User.objects.filter(role=UserRole.ADMIN).first()
        if admin_user:
            msg_text = (
                f"🚨 **New Lookup Request** 🚨\n"
                f"📱 **Number:** {req.mobile_number}\n"
                f"📶 **TSP:** {req.tsp.name}\n"
                f"🏢 **Station:** {req.station_name or 'N/A'}\n"
                f"📋 **CR No:** {req.cr_no or 'N/A'}\n"
                f"💬 **Remarks:** {req.remarks or 'N/A'}"
            )
            chat_msg = ChatMessage.objects.create(
                sender=user,
                receiver=admin_user,
                request=req,
                message=msg_text
            )
            save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)

    @action(detail=True, methods=['post'], url_path='admin-review')
    def admin_review(self, request, pk=None):
        """Admin approves or rejects the request"""
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Only admins can review requests."}, status=status.HTTP_403_FORBIDDEN)
            
        req = self.get_object()
        if req.status != RequestStatus.PENDING:
            return Response({"detail": "Request is not in PENDING state."}, status=status.HTTP_400_BAD_REQUEST)
            
        action_type = request.data.get('action') # 'APPROVE' or 'REJECT'
        remarks = request.data.get('remarks', '')

        if action_type == 'APPROVE':
            req.status = RequestStatus.APPROVED
            req.remarks = remarks
            req.forwarded_at = timezone.now()
            req.save()
            
            # Immediately auto forward approved requests to TSP
            req.status = RequestStatus.FORWARDED
            req.save()
            
            sms_msg, tsp_number = build_tsp_forward_sms(req)

            # Offload approved review actions to background thread
            def _bg_approve():
                try:
                    RequestStatusLog.objects.create(
                        request=req,
                        status=RequestStatus.APPROVED,
                        changed_by=request.user,
                        remarks=remarks
                    )
                    
                    log_activity("Request Approved", request.user, request=req, details=remarks)
                    create_notification(
                        req.officer, 
                        "Request Approved", 
                        f"Your request #{req.id} for {req.mobile_number} has been approved by admin. Remarks: {remarks}"
                    )
                    
                    RequestStatusLog.objects.create(
                        request=req,
                        status=RequestStatus.FORWARDED,
                        changed_by=request.user,
                        remarks="Automatically forwarded to TSP upon approval."
                    )
                    log_activity("Request Forwarded to TSP", request.user, request=req)
                    
                    # Trigger real TextBee SMS to TSP upon approval
                    SMSLog.objects.create(
                        request=req,
                        direction='SENT',
                        operator=req.tsp.name,
                        tsp_number=tsp_number or 'Not Configured',
                        message=sms_msg
                    )
                    if tsp_number:
                        send_textbee_sms(tsp_number, sms_msg)

                    # Notify TSP
                    tsp_users = User.objects.filter(role=UserRole.TSP, tsp_provider=req.tsp)
                    for t_user in tsp_users:
                        create_notification(
                            t_user, 
                            "New Request Assigned", 
                            f"A new request for {req.mobile_number} has been assigned to you."
                        )

                    # Save request update to file database
                    save_request_to_file(req.id, RequestSerializer(req).data)

                    # Mirror to Supabase
                    async_sync_user(request.user)
                    async_save_request(req)
                    AdminForwardRequest.objects.create(
                        request=req,
                        admin=request.user,
                        tsp=req.tsp,
                        forwarded_message=sms_msg,
                        status='Forwarded'
                    )
                    async_save_admin_forward_request(
                        req, request.user,
                        message=sms_msg,
                    )
                    async_log_status(
                        req, request.user,
                        action_type="Admin Approve",
                        details=remarks,
                        old_status="Submitted",
                        new_status="Forwarded_To_TSP",
                    )

                    # Send chat message notification about the status change
                    msg_text = (
                        f"🔄 **Request Status Update** 🔄\n"
                        f"Status: **{req.get_status_display()}**\n"
                        f"Remarks: {remarks or 'None'}"
                    )
                    chat_msg = ChatMessage.objects.create(
                        sender=request.user,
                        receiver=req.officer,
                        request=req,
                        message=msg_text
                    )
                    save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)
                except Exception as e:
                    print(f"[BG_APPROVE ERROR] {e}")
                finally:
                    try:
                        from django.db import connections
                        connections.close_all()
                    except Exception:
                        pass

            import threading
            from django.db import transaction
            transaction.on_commit(lambda: threading.Thread(target=_bg_approve, daemon=True).start())

        elif action_type == 'REJECT':
            req.status = RequestStatus.REJECTED
            req.remarks = remarks
            req.save()
            
            def _bg_reject():
                try:
                    RequestStatusLog.objects.create(
                        request=req,
                        status=RequestStatus.REJECTED,
                        changed_by=request.user,
                        remarks=remarks
                    )
                    
                    log_activity("Request Rejected", request.user, request=req, details=remarks)
                    create_notification(
                        req.officer, 
                        "Request Rejected", 
                        f"Your request #{req.id} for {req.mobile_number} was rejected by admin. Remarks: {remarks}"
                    )

                    # Save request update to file database
                    save_request_to_file(req.id, RequestSerializer(req).data)

                    # Mirror to Supabase
                    async_sync_user(request.user)
                    async_save_request(req)
                    async_log_status(
                        req, request.user,
                        action_type="Admin Reject",
                        details=remarks,
                        old_status="Submitted",
                        new_status="Submitted",
                    )

                    # Send chat message notification about the status change
                    msg_text = (
                        f"🔄 **Request Status Update** 🔄\n"
                        f"Status: **{req.get_status_display()}**\n"
                        f"Remarks: {remarks or 'None'}"
                    )
                    chat_msg = ChatMessage.objects.create(
                        sender=request.user,
                        receiver=req.officer,
                        request=req,
                        message=msg_text
                    )
                    save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)
                except Exception as e:
                    print(f"[BG_REJECT ERROR] {e}")
                finally:
                    try:
                        from django.db import connections
                        connections.close_all()
                    except Exception:
                        pass

            import threading
            from django.db import transaction
            transaction.on_commit(lambda: threading.Thread(target=_bg_reject, daemon=True).start())
        else:
            return Response({"detail": "Invalid action. Use 'APPROVE' or 'REJECT'."}, status=status.HTTP_400_BAD_REQUEST)

        return Response(RequestSerializer(req).data)

    @action(detail=True, methods=['post'], url_path='forward-to-tsp')
    def forward_to_tsp(self, request, pk=None):
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Only admins can forward requests."}, status=status.HTTP_403_FORBIDDEN)
            
        req = self.get_object()
        req.status = RequestStatus.FORWARDED
        req.admin_status = 'Forwarded to TSP'
        req.forwarded_at = timezone.now()
        req.save()
        
        # We need to build the SMS message before sending
        sms_msg, tsp_number = build_tsp_forward_sms(req)

        # Offload approved review actions to background thread
        def _bg_forward():
            try:
                # 1. Create SMS log
                SMSLog.objects.create(
                    request=req,
                    direction='SENT',
                    operator=req.tsp.name,
                    tsp_number=tsp_number or 'Not Configured',
                    message=sms_msg
                )
                
                # 2. Trigger TextBee SMS
                if tsp_number:
                    send_textbee_sms(tsp_number, sms_msg)
                
                # 3. Create RequestStatusLog
                RequestStatusLog.objects.create(
                    request=req,
                    status=RequestStatus.FORWARDED,
                    changed_by=request.user,
                    remarks=f"Request forwarded to TSP: {req.tsp.name}"
                )
                
                # 4. Log Activity
                log_activity("Request Forwarded to TSP", request.user, request=req, details=f"Forwarded to {req.tsp.name}")
                
                # 5. Notify TSP
                tsp_users = User.objects.filter(role=UserRole.TSP, tsp_provider=req.tsp)
                for t_user in tsp_users:
                    create_notification(
                        t_user,
                        "New Request Assigned",
                        f"A new request for {req.mobile_number} has been forwarded to you."
                    )
                
                # 6. Save request update to file database
                save_request_to_file(req.id, RequestSerializer(req).data)

                # 7. Mirror to Supabase
                async_sync_user(request.user)
                async_save_request(req)
                AdminForwardRequest.objects.create(
                    request=req,
                    admin=request.user,
                    tsp=req.tsp,
                    forwarded_message=sms_msg,
                    status='Forwarded'
                )
                async_save_admin_forward_request(
                    req, request.user,
                    message=sms_msg,
                )
                async_log_status(
                    req, request.user,
                    action_type="Admin Forwarded To TSP",
                    details=f"Forwarded to {req.tsp.name}",
                    old_status="Sent_To_Admin",
                    new_status="Forwarded_To_TSP",
                )

                # 8. Send chat message notification
                msg_text = (
                    f"🔄 **Request Status Update** 🔄\n"
                    f"Status: **Forwarded to TSP**\n"
                    f"TSP: **{req.tsp.name}**"
                )
                chat_msg = ChatMessage.objects.create(
                    sender=request.user,
                    receiver=req.officer,
                    request=req,
                    message=msg_text
                )
                save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)
            except Exception as e:
                print(f"[BG_FORWARD ERROR] {e}")
            finally:
                try:
                    from django.db import connections
                    connections.close_all()
                except Exception:
                    pass

        import threading
        from django.db import transaction
        transaction.on_commit(lambda: threading.Thread(target=_bg_forward, daemon=True).start())
        
        return Response(RequestSerializer(req).data)

    @action(detail=True, methods=['post'], url_path='tsp-accept')
    def tsp_accept(self, request, pk=None):
        if request.user.role != UserRole.TSP:
            return Response({"detail": "Only TSP representatives can accept requests."}, status=status.HTTP_403_FORBIDDEN)
            
        req = self.get_object()
        if req.tsp != request.user.tsp_provider:
            return Response({"detail": "You do not have permission to modify this request."}, status=status.HTTP_403_FORBIDDEN)
            
        req.status = RequestStatus.PROCESSING
        req.admin_status = 'Accepted by TSP'
        req.save()
        
        def _bg_accept():
            try:
                RequestStatusLog.objects.create(
                    request=req,
                    status=RequestStatus.PROCESSING,
                    changed_by=request.user,
                    remarks="TSP accepted request, now processing."
                )
                
                log_activity("Request Accepted by TSP", request.user, request=req)
                
                # Notify Admin
                notify_admins(
                    "Request Accepted by TSP",
                    f"TSP {req.tsp.name} accepted request #{req.id} for {req.mobile_number}."
                )
                
                # Save request update to file database
                save_request_to_file(req.id, RequestSerializer(req).data)
                
                # Mirror to Supabase
                async_sync_user(request.user)
                async_save_request(req)
                async_log_status(
                    req, request.user,
                    action_type="TSP Accepted Request",
                    details="TSP accepted request, now processing.",
                    old_status="Forwarded_To_TSP",
                    new_status="Forwarded_To_TSP",
                )
            except Exception as e:
                print(f"[BG_ACCEPT ERROR] {e}")
            finally:
                try:
                    from django.db import connections
                    connections.close_all()
                except Exception:
                    pass

        import threading
        from django.db import transaction
        transaction.on_commit(lambda: threading.Thread(target=_bg_accept, daemon=True).start())

        return Response(RequestSerializer(req).data)

    @action(detail=True, methods=['post'], url_path='tsp-reject')
    def tsp_reject(self, request, pk=None):
        if request.user.role != UserRole.TSP:
            return Response({"detail": "Only TSP representatives can reject requests."}, status=status.HTTP_403_FORBIDDEN)
            
        req = self.get_object()
        if req.tsp != request.user.tsp_provider:
            return Response({"detail": "You do not have permission to modify this request."}, status=status.HTTP_403_FORBIDDEN)
            
        req.status = RequestStatus.REJECTED
        req.admin_status = 'Rejected by TSP'
        req.save()
        
        def _bg_reject():
            try:
                RequestStatusLog.objects.create(
                    request=req,
                    status=RequestStatus.REJECTED,
                    changed_by=request.user,
                    remarks="TSP rejected the request."
                )
                
                log_activity("Request Rejected by TSP", request.user, request=req)
                
                # Notify Admin
                notify_admins(
                    "Request Rejected by TSP",
                    f"TSP {req.tsp.name} rejected request #{req.id} for {req.mobile_number}."
                )
                
                # Save request update to file database
                save_request_to_file(req.id, RequestSerializer(req).data)
                
                # Mirror to Supabase
                async_sync_user(request.user)
                async_save_request(req)
                async_log_status(
                    req, request.user,
                    action_type="TSP Rejected Request",
                    details="TSP rejected the request.",
                    old_status="Forwarded_To_TSP",
                    new_status="Submitted",
                )
            except Exception as e:
                print(f"[BG_REJECT ERROR] {e}")
            finally:
                try:
                    from django.db import connections
                    connections.close_all()
                except Exception:
                    pass

        import threading
        from django.db import transaction
        transaction.on_commit(lambda: threading.Thread(target=_bg_reject, daemon=True).start())

        return Response(RequestSerializer(req).data)

    @action(detail=True, methods=['post'], url_path='tsp-respond')
    def tsp_respond(self, request, pk=None):
        """TSP representative uploads number information"""
        if request.user.role != UserRole.TSP:
            return Response({"detail": "Only TSP representatives can submit details."}, status=status.HTTP_403_FORBIDDEN)
            
        req = self.get_object()
        if req.tsp != request.user.tsp_provider:
            return Response({"detail": "You do not have permission to respond on behalf of this TSP."}, status=status.HTTP_403_FORBIDDEN)
            
        details = request.data.get('details')
        notes = request.data.get('notes', '')
        
        if not details:
            return Response({"detail": "Information details are required."}, status=status.HTTP_400_BAD_REQUEST)

        # Check if this is an acknowledgment
        is_ack = is_acknowledgment_message(details)

        # Check current system settings dynamically at response time
        from api.models import SystemSetting, PermissionSetting
        absent_mode_setting = SystemSetting.objects.filter(key='admin_absent_mode').first()
        is_absent_mode_on = absent_mode_setting.value.lower() == 'true' if absent_mode_setting else False

        absent_mode_type_setting = SystemSetting.objects.filter(key='admin_absent_mode_type').first()
        absent_mode_type = absent_mode_type_setting.value.lower() if absent_mode_type_setting else 'all'

        direct_forward_setting = SystemSetting.objects.filter(key='allow_direct_forwarding').first()
        is_direct_forward_on = direct_forward_setting.value.lower() == 'true' if direct_forward_setting else False

        admin_status_setting = SystemSetting.objects.filter(key='admin_status').first()
        admin_status = admin_status_setting.value.lower() if admin_status_setting else 'online'
        is_admin_offline = admin_status in ['offline', 'away']

        has_direct_permission = False
        try:
            perm = PermissionSetting.objects.get(officer=req.officer)
            has_direct_permission = perm.direct_forward_allowed
        except Exception:
            pass

        should_absent_complete = False
        if req.is_absent_approved:
            should_absent_complete = True
        elif is_absent_mode_on:
            if absent_mode_type == 'all':
                should_absent_complete = True
            elif absent_mode_type == 'specific':
                should_absent_complete = has_direct_permission

        should_auto_complete = (
            req.is_direct_forwarded or 
            req.is_auto_approved or 
            should_absent_complete or 
            is_direct_forward_on or 
            has_direct_permission
        )

        flow_title = "Direct Forward Mode" if (req.is_direct_forwarded or req.is_auto_approved or is_direct_forward_on or has_direct_permission) else "Admin Absent Mode"
        flow_remarks = "Direct Forward Auto-Flow" if (req.is_direct_forwarded or req.is_auto_approved or is_direct_forward_on or has_direct_permission) else "Admin Absent Auto-Flow"
        flow_details = "direct-forwarded" if (req.is_direct_forwarded or req.is_auto_approved or is_direct_forward_on or has_direct_permission) else "absent-approved"

        # Update Request fields
        if req.response:
            if details not in req.response:
                req.response = f"{req.response}\n\n[Additional Response]: {details}"
        else:
            req.response = details
        req.response_date = timezone.now()
        
        # Guard: prevent TSP from reverting already-completed/closed requests, but still record their response details.
        if req.status not in [RequestStatus.COMPLETED, RequestStatus.CLOSED]:
            if is_ack and not should_auto_complete:
                req.status = RequestStatus.PROCESSING
                req.admin_status = 'Acknowledgment Received'
            else:
                if should_auto_complete:
                    req.status = RequestStatus.COMPLETED
                    req.admin_status = 'Completed & Sent to Officer'
                    req.response_date = timezone.now()
                else:
                    # FIX: Set to TSP_RESPONDED so admin can review & forward.
                    req.status = RequestStatus.TSP_RESPONDED
                    req.admin_status = 'SMS Response Received'
        if notes:
            req.admin_remarks = f"TSP Notes: {notes}"
        req.save()

        # Save/update the legacy TSPResponse model for tests and backward compatibility
        _parsed = parse_tsp_sms_response(details, tsp_name=req.tsp.name)
        parsed_status = _parsed['subscriber_status']
        parsed_circle = _parsed['circle']
        parsed_notes  = notes or _parsed['additional_notes']
        parsed_date   = _parsed['activation_date']

        # Determine response status
        if is_ack:
            response_status = 'Sent to Officer' if should_auto_complete else 'Received'
        else:
            if req.status in [RequestStatus.COMPLETED, RequestStatus.CLOSED] or should_auto_complete:
                response_status = 'Sent to Officer'
            else:
                response_status = 'Received'

        resp = TSPResponse.objects.create(
            request=req,
            details=details,
            submitted_by=request.user,
            created_by=request.user,
            timestamp=timezone.now(),
            mobile_number=req.mobile_number,
            tsp_provider=req.tsp.name,
            status=response_status,
            response_date=timezone.now(),
            subscriber_status=parsed_status,
            circle=parsed_circle,
            activation_date=parsed_date,
            additional_notes=parsed_notes,
        )
        save_response_to_queue(resp.id, TSPResponseSerializer(resp).data, resp.tsp_provider)

        # Offload approved review actions to background thread
        def _bg_respond():
            try:
                # Create SMS log
                SMSLog.objects.create(
                    request=req,
                    direction='RECEIVED',
                    operator=req.tsp.name,
                    tsp_number=req.tsp.mobile_number or 'Not Configured',
                    message=f"TSP Response: {details}\nNotes: {notes or 'None'}"
                )

                if req.status not in [RequestStatus.COMPLETED, RequestStatus.CLOSED]:
                    RequestStatusLog.objects.create(
                        request=req,
                        status=req.status,
                        changed_by=request.user,
                        remarks=f"TSP response submitted by {request.user.username}. Notes: {notes}"
                    )
                
                log_activity("TSP Response Received", request.user, request=req, details=f"Response data: {details[:100]}...")
                
                # Notify Admins
                notify_admins(
                    "TSP Response Received", 
                    f"TSP {req.tsp.name} has responded to request #{req.id} for mobile number {req.mobile_number}."
                )

                # Save request update to file database
                save_request_to_file(req.id, RequestSerializer(req).data)
                
                # Send chat message notification to ADMIN or OFFICER
                admin_user = User.objects.filter(role=UserRole.ADMIN).first()
                if not is_ack:
                    if should_auto_complete:
                        msg_text = (
                            f"📥 **TSP Response Received ({flow_title} — Sent to Officer)** 📥\n"
                            f"📱 **Mobile:** {req.mobile_number}\n"
                            f"📶 **TSP:** {req.tsp.name}\n"
                            f"📋 **Subscriber Status:** {parsed_status}\n"
                            f"📍 **Circle/State:** {parsed_circle or 'N/A'}\n"
                            f"📅 **Activation Date:** {parsed_date.strftime('%Y-%m-%d') if parsed_date else 'N/A'}\n"
                            f"📩 **Full Response:** {details}\n"
                            f"✅ This response has been automatically forwarded to the officer."
                        )
                        create_notification(
                            req.officer,
                            "📥 TSP Response Received",
                            f"TSP {req.tsp.name} responded for request #{req.id} ({req.mobile_number})."
                        )
                        chat_msg = ChatMessage.objects.create(
                            sender=request.user,
                            receiver=req.officer,
                            request=req,
                            message=msg_text
                        )
                        save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)
                    else:
                        msg_text = (
                            f"📥 **TSP Response Received — Awaiting Admin Review** 📥\n"
                            f"📱 **Mobile:** {req.mobile_number}\n"
                            f"📶 **TSP:** {req.tsp.name}\n"
                            f"📋 **Subscriber Status:** {parsed_status}\n"
                            f"📍 **Circle/State:** {parsed_circle or 'N/A'}\n"
                            f"📅 **Activation Date:** {parsed_date.strftime('%Y-%m-%d') if parsed_date else 'N/A'}\n"
                            f"📩 **Full Response:** {details}\n"
                            f"⚠️ Please review in TSP Replies and forward to the officer."
                        )
                        if admin_user:
                            create_notification(
                                admin_user,
                                "📥 TSP Response Needs Review",
                                f"TSP {req.tsp.name} responded for request #{req.id} ({req.mobile_number}). Please review in TSP Replies and forward to officer."
                            )
                            chat_msg = ChatMessage.objects.create(
                                sender=request.user,
                                receiver=admin_user,
                                request=req,
                                message=msg_text
                            )
                            save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)
                else:
                    msg_text = (
                        f"📶 **TSP Acknowledgment Received** 📶\n"
                        f"TSP: **{req.tsp.name}**\n"
                        f"Details: {details}\n"
                        f"Notes: {notes or 'None'}"
                    )
                    if admin_user:
                        chat_msg = ChatMessage.objects.create(
                            sender=request.user,
                            receiver=admin_user,
                            request=req,
                            message=msg_text
                        )
                        save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)

                # Mirror to Supabase
                async_sync_user(request.user)
                async_save_request(req)
                async_save_tsp_response(req, resp, request.user)
                if is_ack:
                    async_log_status(
                        req, request.user,
                        action_type="TSP Acknowledgment Polled (Auto)",
                        details=f"TSP sent acknowledgment. Content: {details[:120]}",
                        old_status="Forwarded_To_TSP",
                        new_status="Forwarded_To_TSP",
                    )
                else:
                    if should_auto_complete:
                        admin_user = User.objects.filter(role=UserRole.ADMIN).first()
                        async_save_admin_forward_response(req, resp, admin_user)
                        async_log_status(
                            req, request.user,
                            action_type=f"TSP Response Received ({flow_title} — Sent to Officer)",
                            details=f"TSP submitted response: {details[:120]}",
                            old_status="Forwarded_To_TSP",
                            new_status="Forwarded_To_Officer",
                        )
                    else:
                        async_log_status(
                            req, request.user,
                            action_type="TSP Response Received (Pending Admin Review)",
                            details=f"TSP submitted response via app: {details[:120]}",
                            old_status="Forwarded_To_TSP",
                            new_status="TSP_Responded_Pending_Admin",
                        )
            except Exception as e:
                print(f"[BG_RESPOND ERROR] {e}")
            finally:
                try:
                    from django.db import connections
                    connections.close_all()
                except Exception:
                    pass

        import threading
        from django.db import transaction
        transaction.on_commit(lambda: threading.Thread(target=_bg_respond, daemon=True).start())

        return Response(RequestSerializer(req).data)


    @action(detail=True, methods=['post'], url_path='admin-complete')
    def admin_complete(self, request, pk=None):
        """Admin forwards/completes the response to the Field Officer"""
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Only admins can complete requests."}, status=status.HTTP_403_FORBIDDEN)
            
        req = self.get_object()
        if req.status not in [RequestStatus.TSP_RESPONDED, RequestStatus.COMPLETED]:
            return Response(
                {"detail": "Cannot complete request without a valid TSP response. Acknowledgment or pending requests cannot be completed."},
                status=status.HTTP_400_BAD_REQUEST
            )
        admin_remarks = request.data.get('remarks', '')
        req.status = RequestStatus.COMPLETED
        req.admin_status = 'Completed'
        if admin_remarks:
            req.admin_remarks = admin_remarks
            req.remarks = admin_remarks
        req.save()

        # ── Also mark the linked TSPResponse as 'Sent to Officer' ──────────────
        _linked_resp = req.tsp_responses.first()
        if _linked_resp and _linked_resp.status != 'Sent to Officer':
            _linked_resp.status = 'Sent to Officer'
            _linked_resp.response_date = timezone.now()
            _linked_resp.save()
            save_response_to_queue(_linked_resp.id, TSPResponseSerializer(_linked_resp).data, _linked_resp.tsp_provider)

        # Offload approved review actions to background thread
        def _bg_complete():
            try:
                RequestStatusLog.objects.create(
                    request=req,
                    status=RequestStatus.COMPLETED,
                    changed_by=request.user,
                    remarks=admin_remarks or "Response approved and sent to officer."
                )

                # Audit Log - Completed
                approval_time_str = req.created_at.strftime('%Y-%m-%d %H:%M:%S')
                response_time_str = timezone.now().strftime('%Y-%m-%d %H:%M:%S')
                admin_status_val = SystemSetting.objects.filter(key='admin_status').first()
                admin_status_str = admin_status_val.value.capitalize() if admin_status_val else 'Online'
                
                audit_details = (
                    f"Officer Name: {req.officer_name}\n"
                    f"Mobile Number: {req.mobile_number}\n"
                    f"Selected TSP: {req.tsp.name}\n"
                    f"Admin Status: {admin_status_str}\n"
                    f"Auto Approval Time: {approval_time_str if req.is_auto_approved else 'N/A (Manual Review)'}\n"
                    f"Response Time: {response_time_str}"
                )
                ActivityLog.objects.create(
                    action="Audit Log - Completed",
                    user=request.user,
                    request=req,
                    details=audit_details
                )

                log_activity("Response Sent to Officer", request.user, request=req, details=admin_remarks)
                
                # Notify field officer
                create_notification(
                    req.officer,
                    "TSP Request Completed",
                    f"Admin has sent the TSP response for request #{req.id} ({req.mobile_number}). Response: {req.response}"
                )

                # Save request update to file database
                save_request_to_file(req.id, RequestSerializer(req).data)

                # Mirror to Supabase
                async_sync_user(request.user)
                async_save_request(req)
                tsp_resp_obj = req.tsp_responses.first()
                async_save_admin_forward_response(req, tsp_resp_obj, request.user)
                async_log_status(
                    req, request.user,
                    action_type="Admin Forwarded Response To Officer",
                    details=admin_remarks or "Response approved and sent to officer.",
                    old_status="Response_Received_From_TSP",
                    new_status="Forwarded_To_Officer",
                )

                # Send chat message notification
                msg_text = (
                    f"✅ **Request Completed & Sent to Officer** ✅\n"
                    f"Response Details: {req.response}\n"
                    f"Admin Remarks: {admin_remarks or 'None'}"
                )
                chat_msg = ChatMessage.objects.create(
                    sender=request.user,
                    receiver=req.officer,
                    request=req,
                    message=msg_text
                )
                save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)
            except Exception as e:
                print(f"[BG_COMPLETE ERROR] {e}")
            finally:
                try:
                    from django.db import connections
                    connections.close_all()
                except Exception:
                    pass

        import threading
        from django.db import transaction
        transaction.on_commit(lambda: threading.Thread(target=_bg_complete, daemon=True).start())

        return Response(RequestSerializer(req).data)

    @action(detail=True, methods=['post'], url_path='close-request')
    def close_request(self, request, pk=None):
        req = self.get_object()
        req.status = RequestStatus.CLOSED
        req.admin_status = 'Closed'
        req.save()

        def _bg_close():
            try:
                RequestStatusLog.objects.create(
                    request=req,
                    status=RequestStatus.CLOSED,
                    changed_by=request.user,
                    remarks="Request closed."
                )
                save_request_to_file(req.id, RequestSerializer(req).data)
                
                # Log activity
                log_activity("Request Closed", request.user, request=req)

                # Mirror to Supabase
                async_sync_user(request.user)
                async_save_request(req)
                async_log_status(
                    req, request.user,
                    action_type="Request Closed",
                    details="Request closed.",
                    old_status="Forwarded_To_Officer",
                    new_status="Completed",
                )
            except Exception as e:
                print(f"[BG_CLOSE ERROR] {e}")
            finally:
                try:
                    from django.db import connections
                    connections.close_all()
                except Exception:
                    pass

        import threading
        from django.db import transaction
        transaction.on_commit(lambda: threading.Thread(target=_bg_close, daemon=True).start())

        return Response(RequestSerializer(req).data)

    @action(detail=True, methods=['post'], url_path='tsp-sms-response')
    def tsp_sms_response(self, request, pk=None):
        """
        Simulates receiving an inbound SMS response from TSP via the configured inbound number.
        Admin logs: the TSP sent an SMS to our inbound number (e.g. 7353224350) with subscriber info.
        This triggers the same flow as tsp-respond.
        """
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Only admins can log inbound TSP SMS responses."}, status=status.HTTP_403_FORBIDDEN)

        req = self.get_object()

        from_number = request.data.get('from_number', '')   # The TSP's number that sent the SMS
        inbound_number = request.data.get('inbound_number', '')  # Our configured inbound number
        sms_body = request.data.get('sms_body', '')         # The SMS content from TSP

        if not sms_body:
            return Response({"detail": "SMS body/content is required."}, status=status.HTTP_400_BAD_REQUEST)

        # [DISABLED] Acknowledgment messages are now treated as standard replies
        # so they do not block forwarding or leave requests stuck in Processing.
        # if is_acknowledgment_message(sms_body):
        #     # Acknowledgment message received. Update request status to PROCESSING and admin status.
        #     is_completed_or_closed = req.status in [RequestStatus.COMPLETED, RequestStatus.CLOSED]
        #     if not is_completed_or_closed:
        #         req.status = RequestStatus.PROCESSING
        #         req.admin_status = 'Acknowledgment Received'
        #         req.save()
        # 
        #     # Create SMS Log — direction RECEIVED
        #     SMSLog.objects.create(
        #         request=req,
        #         direction='RECEIVED',
        #         operator=req.tsp.name,
        #         tsp_number=from_number or req.tsp.mobile_number or 'Unknown',
        #         message=f"Inbound SMS to {inbound_number or req.tsp.inbound_number or 'Inbound Number'}\nFrom: {from_number}\n\n{sms_body}"
        #     )
        # 
        #     # Create TSPResponse for acknowledgment
        #     admin_user = User.objects.filter(role=UserRole.ADMIN).first()
        #     response_status = 'Sent to Officer' if is_completed_or_closed else 'Received'
        #     resp, created = TSPResponse.objects.update_or_create(
        #         request=req,
        #         defaults={
        #             'details': sms_body,
        #             'submitted_by': admin_user or request.user,
        #             'created_by': admin_user or request.user,
        #             'timestamp': timezone.now(),
        #             'mobile_number': req.mobile_number,
        #             'tsp_provider': req.tsp.name,
        #             'status': response_status,
        #             'response_date': timezone.now(),
        #             'subscriber_status': 'Under Process',
        #             'circle': '',
        #             'activation_date': None,
        #             'additional_notes': f"Inbound SMS from {from_number}"
        #         }
        #     )
        #     save_response_to_queue(resp.id, TSPResponseSerializer(resp).data, resp.tsp_provider)
        # 
        #     # Request Status Log
        #     RequestStatusLog.objects.create(
        #         request=req,
        #         status=RequestStatus.COMPLETED if is_completed_or_closed else RequestStatus.PROCESSING,
        #         changed_by=request.user,
        #         remarks=f"Inbound acknowledgment SMS response received from {from_number} on number {inbound_number}."
        #     )
        # 
        #     log_activity(
        #         "Inbound TSP SMS Acknowledgment",
        #         request.user,
        #         request=req,
        #         details=f"TSP sent acknowledgment SMS from {from_number} to inbound number {inbound_number}. Content: {sms_body[:100]}"
        #     )
        # 
        #     # Notify admins
        #     notify_admins(
        #         "TSP SMS Acknowledgment Received",
        #         f"TSP {req.tsp.name} acknowledged request #{req.id} (Mobile: {req.mobile_number}) and is processing it."
        #     )
        # 
        #     # Chat message
        #     msg_text = (
        #         f"📩 **Inbound TSP SMS Acknowledgment** 📩\n"
        #         f"TSP: **{req.tsp.name}**\n"
        #         f"From Number: {from_number or 'Unknown'}\n"
        #         f"To Inbound Number: {inbound_number or req.tsp.inbound_number or 'Configured Inbound'}\n\n"
        #         f"Acknowledgment SMS Content:\n{sms_body}"
        #     )
        #     chat_msg = ChatMessage.objects.create(
        #         sender=admin_user or request.user,
        #         receiver=req.officer,
        #         request=req,
        #         message=msg_text
        #     )
        #     save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)
        # 
        #     # Save request update to file database
        #     save_request_to_file(req.id, RequestSerializer(req).data)
        # 
        #     # ── Mirror to Supabase ───────────────────────────────────────────────
        #     async_sync_user(request.user)
        #     async_save_request(req)
        #     async_save_tsp_response(req, resp, None)
        #     async_log_status(
        #         req, request.user,
        #         action_type="TSP Acknowledgment Received (SMS)",
        #         details=f"Inbound acknowledgment SMS from {from_number}: {sms_body[:100]}",
        #         old_status="Forwarded_To_TSP",
        #         new_status="Forwarded_To_TSP",
        #     )
        #     # ────────────────────────────────────────────────────────────────────
        # 
        #     return Response(RequestSerializer(req).data)

        # Check current system settings dynamically at response receipt time
        from api.models import SystemSetting, PermissionSetting
        absent_mode_setting = SystemSetting.objects.filter(key='admin_absent_mode').first()
        is_absent_mode_on = absent_mode_setting.value.lower() == 'true' if absent_mode_setting else False

        absent_mode_type_setting = SystemSetting.objects.filter(key='admin_absent_mode_type').first()
        absent_mode_type = absent_mode_type_setting.value.lower() if absent_mode_type_setting else 'all'

        direct_forward_setting = SystemSetting.objects.filter(key='allow_direct_forwarding').first()
        is_direct_forward_on = direct_forward_setting.value.lower() == 'true' if direct_forward_setting else False

        admin_status_setting = SystemSetting.objects.filter(key='admin_status').first()
        admin_status = admin_status_setting.value.lower() if admin_status_setting else 'online'
        is_admin_offline = admin_status in ['offline', 'away']

        has_direct_permission = False
        try:
            perm = PermissionSetting.objects.get(officer=req.officer)
            has_direct_permission = perm.direct_forward_allowed
        except Exception:
            pass

        should_absent_complete = False
        if req.is_absent_approved:
            should_absent_complete = True
        elif is_absent_mode_on:
            if absent_mode_type == 'all':
                should_absent_complete = True
            elif absent_mode_type == 'specific':
                should_absent_complete = has_direct_permission

        should_auto_complete = (
            req.is_direct_forwarded or 
            req.is_auto_approved or 
            should_absent_complete or 
            is_direct_forward_on or 
            has_direct_permission
        )

        # Update request with the SMS response
        if req.response:
            if sms_body not in req.response:
                req.response = f"{req.response}\n\n[Additional Response]: {sms_body}"
        else:
            req.response = sms_body
        req.response_date = timezone.now()
        is_completed_or_closed = req.status in [RequestStatus.COMPLETED, RequestStatus.CLOSED]
        
        if not is_completed_or_closed:
            if should_auto_complete:
                req.status = RequestStatus.COMPLETED
                req.admin_status = 'Completed'
            else:
                req.status = RequestStatus.TSP_RESPONDED
                req.admin_status = 'SMS Response Received'
        req.save()

        # Create SMS Log — direction RECEIVED
        SMSLog.objects.create(
            request=req,
            direction='RECEIVED',
            operator=req.tsp.name,
            tsp_number=from_number or req.tsp.mobile_number or 'Unknown',
            message=f"Inbound SMS to {inbound_number or req.tsp.inbound_number or 'Inbound Number'}\nFrom: {from_number}\n\n{sms_body}"
        )

        # Save/update TSPResponse for backward compatibility
        _parsed = parse_tsp_sms_response(sms_body, tsp_name=req.tsp.name)
        parsed_status = _parsed['subscriber_status']
        parsed_circle = _parsed['circle']
        parsed_notes  = _parsed['additional_notes']
        parsed_date   = _parsed['activation_date']

        response_status = 'Sent to Officer' if (is_completed_or_closed or should_auto_complete) else 'Received'

        resp = TSPResponse.objects.create(
            request=req,
            details=sms_body,
            submitted_by=request.user,
            created_by=request.user,
            timestamp=timezone.now(),
            mobile_number=req.mobile_number,
            tsp_provider=req.tsp.name,
            status=response_status,
            response_date=timezone.now(),
            subscriber_status=parsed_status,
            circle=parsed_circle,
            activation_date=parsed_date,
            additional_notes=parsed_notes,
        )
        save_response_to_queue(resp.id, TSPResponseSerializer(resp).data, resp.tsp_provider)

        formatted_details = (
            f"Subscriber Status: {parsed_status}\n"
            f"Circle/State: {parsed_circle}\n"
            f"Activation Date: {parsed_date.strftime('%Y-%m-%d') if parsed_date else 'N/A'}\n"
            f"Additional Notes: {parsed_notes or 'None'}"
        )

        if should_auto_complete and not is_completed_or_closed:
            flow_title = "Direct Forward Mode" if (req.is_direct_forwarded or req.is_auto_approved or is_direct_forward_on or has_direct_permission) else "Admin Absent Mode"
            flow_remarks = "Direct Forward Auto-Flow" if (req.is_direct_forwarded or req.is_auto_approved or is_direct_forward_on or has_direct_permission) else "Admin Absent Auto-Flow"
            flow_details = "direct-forwarded" if (req.is_direct_forwarded or req.is_auto_approved or is_direct_forward_on or has_direct_permission) else "absent-approved"

            RequestStatusLog.objects.create(
                request=req,
                status=RequestStatus.COMPLETED,
                changed_by=request.user,
                remarks=f"Inbound SMS response automatically completed ({flow_remarks}) matching request #{req.id}."
            )

            log_activity(
                "Auto Inbound TSP SMS Response Completed",
                request.user,
                request=req,
                details=f"TSP response auto-forwarded to officer because request was {flow_details}. Content: {sms_body[:100]}"
            )

            create_notification(
                req.officer,
                f"TSP Request Completed ({flow_title})",
                f"TSP response for request #{req.id} ({req.mobile_number}) has been auto-completed: {req.response}"
            )

            # Send chat message to officer
            response_summary = (
                f"✅ **TSP Response Auto-Forwarded ({flow_title})** ✅\n"
                f"📱 **Mobile:** {req.mobile_number}\n"
                f"📶 **TSP:** {req.tsp.name}\n"
                f"📋 **Subscriber Status:** {parsed_status}\n"
                f"📍 **Circle/State:** {parsed_circle or 'N/A'}\n"
                f"📅 **Activation Date:** {parsed_date.strftime('%Y-%m-%d') if parsed_date else 'N/A'}\n"
                f"📩 **Full Response:** {sms_body}"
            )
            chat_msg = ChatMessage.objects.create(
                sender=request.user,
                receiver=req.officer,
                request=req,
                message=response_summary
            )
            save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)
            save_request_to_file(req.id, RequestSerializer(req).data)
            
            # Mirror to Supabase
            async_sync_user(request.user)
            async_save_request(req)
            async_save_admin_forward_response(req, resp, request.user)
            async_log_status(
                req, request.user,
                action_type=f"TSP SMS Response Auto-Forwarded ({flow_title})",
                details=formatted_details,
                old_status="Forwarded_To_TSP",
                new_status="Forwarded_To_Officer",
            )
        else:
            RequestStatusLog.objects.create(
                request=req,
                status=RequestStatus.TSP_RESPONDED,
                changed_by=request.user,
                remarks=f"Inbound SMS response received from {from_number} on number {inbound_number}."
            )

            log_activity(
                "Inbound TSP SMS Response",
                request.user,
                request=req,
                details=f"TSP sent SMS from {from_number} to inbound number {inbound_number}. Content: {sms_body[:100]}"
            )

            # Notify admins
            notify_admins(
                "TSP SMS Response Received",
                f"TSP {req.tsp.name} sent an SMS response for request #{req.id} (Mobile: {req.mobile_number})."
            )

            # Chat message
            admin_user = User.objects.filter(role=UserRole.ADMIN).first()
            msg_text = (
                f"📩 **Inbound TSP SMS Response** 📩\n"
                f"TSP: **{req.tsp.name}**\n"
                f"From Number: {from_number or 'Unknown'}\n"
                f"To Inbound Number: {inbound_number or req.tsp.inbound_number or 'Configured Inbound'}\n\n"
                f"SMS Content:\n{sms_body}"
            )
            chat_msg = ChatMessage.objects.create(
                sender=admin_user or request.user,
                receiver=req.officer,
                request=req,
                message=msg_text
            )
            save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)
            save_request_to_file(req.id, RequestSerializer(req).data)

            # Mirror to Supabase
            async_sync_user(request.user)
            async_save_request(req)
            async_save_tsp_response(req, resp, None)
            async_log_status(
                req, request.user,
                action_type="TSP SMS Response Polled (Auto) — Pending Admin Review",
                details=f"TSP sent SMS from {from_number}: {sms_body[:100]}",
                old_status="Forwarded_To_TSP",
                new_status="Response_Received_From_TSP",
            )

        return Response(RequestSerializer(req).data)


class AdminDashboardStatsView(views.APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Access Denied"}, status=status.HTTP_403_FORBIDDEN)

        # Background poller runs every 15 seconds automatically.
        # Removing poll_incoming_sms_async() call here to prevent concurrent SQLite DB write lock contentions.
        pass
        requests_qs = Request.objects.all()
        
        # Single database query to aggregate all metrics
        metrics = requests_qs.aggregate(
            total=Count('id'),
            pending=Count('id', filter=Q(status=RequestStatus.PENDING)),
            completed=Count('id', filter=Q(status=RequestStatus.COMPLETED)),
            airtel=Count('id', filter=Q(tsp__code='AIRTEL')),
            jio=Count('id', filter=Q(tsp__code='JIO')),
            vodafone=Count('id', filter=Q(tsp__code='VI')),
            bsnl=Count('id', filter=Q(tsp__code='BSNL')),
            approved=Count('id', filter=Q(status__in=[RequestStatus.FORWARDED, RequestStatus.TSP_RESPONDED, RequestStatus.COMPLETED])),
            rejected=Count('id', filter=Q(status=RequestStatus.REJECTED)),
            auto_approved=Count('id', filter=Q(is_auto_approved=True)),
            direct_tsp=Count('id', filter=Q(is_direct_forwarded=True)),
            absent_approved=Count('id', filter=Q(is_absent_approved=True))
        )

        total_requests = metrics['total'] or 0
        pending_requests = metrics['pending'] or 0
        completed_requests = metrics['completed'] or 0
        airtel_requests = metrics['airtel'] or 0
        jio_requests = metrics['jio'] or 0
        vodafone_requests = metrics['vodafone'] or 0
        bsnl_requests = metrics['bsnl'] or 0
        approved_requests = metrics['approved'] or 0
        rejected_requests = metrics['rejected'] or 0
        auto_approved = metrics['auto_approved'] or 0
        direct_tsp_requests = metrics['direct_tsp'] or 0
        absent_approved_requests = metrics['absent_approved'] or 0

        # TSP-wise reports
        tsp_stats = list(requests_qs.values('tsp__name').annotate(count=Count('id')).order_by('-count'))
        
        # Officer-wise reports
        officer_stats = list(requests_qs.values('officer__username').annotate(count=Count('id')).order_by('-count'))

        # Recent activities
        recent_activities = ActivityLog.objects.all().select_related('user', 'request').order_by('-timestamp')[:10]
        recent_activities_data = ActivityLogSerializer(recent_activities, many=True).data

        # Single database query to fetch settings
        settings_dict = {s.key: s.value for s in SystemSetting.objects.filter(key__in=[
            'auto_approval_mode', 'auto_routing_mode', 'admin_absent_mode',
            'admin_absent_mode_type', 'allow_direct_forwarding', 'admin_status', 'admin_mobile_number'
        ])}

        is_auto_approve_on = settings_dict.get('auto_approval_mode', 'false').lower() == 'true'
        is_auto_routing_on = settings_dict.get('auto_routing_mode', 'false').lower() == 'true'
        is_absent_mode_on = settings_dict.get('admin_absent_mode', 'false').lower() == 'true'
        absent_mode_type = settings_dict.get('admin_absent_mode_type', 'all').lower()
        is_direct_forward_on = settings_dict.get('allow_direct_forwarding', 'false').lower() == 'true'
        admin_status = settings_dict.get('admin_status', 'online').lower()
        admin_mobile_number = settings_dict.get('admin_mobile_number', '9844281875')

        return Response({
            'total_requests': total_requests,
            'pending_requests': pending_requests,
            'approved_requests': approved_requests,
            'rejected_requests': rejected_requests,
            'auto_approved_requests': auto_approved,
            'tsp_stats': tsp_stats,
            'officer_stats': officer_stats,
            'recent_activities': recent_activities_data,
            'auto_approval_mode': is_auto_approve_on,
            'auto_routing_mode': is_auto_routing_on,
            'admin_absent_mode': is_absent_mode_on,
            'admin_absent_mode_type': absent_mode_type,
            'allow_direct_forwarding': is_direct_forward_on,
            'admin_status': admin_status,
            'admin_mobile_number': admin_mobile_number,
            'direct_tsp_requests': direct_tsp_requests,
            'absent_approved_requests': absent_approved_requests,
            'airtel_requests': airtel_requests,
            'jio_requests': jio_requests,
            'vodafone_requests': vodafone_requests,
            'bsnl_requests': bsnl_requests,
            'completed_requests': completed_requests,
        })

class OfficerDashboardStatsView(views.APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        if request.user.role != UserRole.OFFICER:
            return Response({"detail": "Access Denied"}, status=status.HTTP_403_FORBIDDEN)

        requests_qs = Request.objects.filter(officer=request.user)
        
        total_requests = requests_qs.count()
        pending_requests = requests_qs.filter(status=RequestStatus.PENDING).count()
        completed_requests = requests_qs.filter(status=RequestStatus.COMPLETED).count()
        rejected_requests = requests_qs.filter(status=RequestStatus.REJECTED).count()

        # Check permission status
        try:
            perm = PermissionSetting.objects.get(officer=request.user)
            has_direct_permission = perm.direct_forward_allowed
        except PermissionSetting.DoesNotExist:
            has_direct_permission = False

        return Response({
            'total_requests': total_requests,
            'pending_requests': pending_requests,
            'completed_requests': completed_requests,
            'rejected_requests': rejected_requests,
            'direct_forward_permission': has_direct_permission
        })

class UserProfileView(views.APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        data = UserSerializer(request.user).data
        if request.user.role == UserRole.ADMIN:
            setting = SystemSetting.objects.filter(key='admin_mobile_number').first()
            data['phone_number'] = setting.value if setting else '9844281875'
        return Response(data)

    def put(self, request):
        user = request.user
        username = request.data.get('username')
        password = request.data.get('password')
        phone_number = request.data.get('phone_number')

        if username:
            username = username.strip()
            if User.objects.filter(username=username).exclude(pk=user.pk).exists():
                return Response({"detail": "Username already taken"}, status=status.HTTP_400_BAD_REQUEST)
            user.username = username

        if password:
            user.set_password(password)

        user.save()

        if user.role == UserRole.ADMIN and phone_number is not None:
            SystemSetting.objects.update_or_create(
                key='admin_mobile_number',
                defaults={'value': str(phone_number).strip()}
            )

        data = UserSerializer(user).data
        if user.role == UserRole.ADMIN:
            setting = SystemSetting.objects.filter(key='admin_mobile_number').first()
            data['phone_number'] = setting.value if setting else '9844281875'

        # Log profile update activity
        log_activity(
            "Profile Updated",
            user,
            details=f"Updated profile details. Username: {user.username}"
        )

        return Response(data)

class TSPDashboardStatsView(views.APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        if request.user.role != UserRole.TSP or not request.user.tsp_provider:
            return Response({"detail": "Access Denied"}, status=status.HTTP_403_FORBIDDEN)

        requests_qs = Request.objects.filter(tsp=request.user.tsp_provider)
        
        assigned_requests = requests_qs.filter(status__in=[RequestStatus.FORWARDED, RequestStatus.PROCESSING]).count()
        responded_requests = requests_qs.filter(status=RequestStatus.TSP_RESPONDED).count()
        completed_requests = requests_qs.filter(status=RequestStatus.COMPLETED).count()

        direct_forward_setting = SystemSetting.objects.filter(key='allow_direct_forwarding').first()
        is_direct_messaging_on = direct_forward_setting.value.lower() == 'true' if direct_forward_setting else False

        admin_user = User.objects.filter(role=UserRole.ADMIN).first()

        return Response({
            'assigned_requests': assigned_requests,
            'responded_requests': responded_requests,
            'completed_requests': completed_requests,
            'tsp_name': request.user.tsp_provider.name,
            'allow_direct_messaging': is_direct_messaging_on,
            'admin_user_id': admin_user.id if admin_user else None,
        })

class SystemSettingView(views.APIView):
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request):
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Only admins can change settings."}, status=status.HTTP_403_FORBIDDEN)

        auto_approval = request.data.get('auto_approval_mode')
        auto_routing = request.data.get('auto_routing_mode')
        admin_absent_mode = request.data.get('admin_absent_mode')
        allow_direct_forwarding = request.data.get('allow_direct_forwarding')
        admin_status = request.data.get('admin_status')
        admin_mobile_number = request.data.get('admin_mobile_number')
        
        admin_absent_mode_type = request.data.get('admin_absent_mode_type')
        
        response_data = {}
        
        if auto_approval is not None:
            setting, created = SystemSetting.objects.update_or_create(
                key='auto_approval_mode',
                defaults={'value': str(auto_approval).lower()}
            )
            log_activity(
                "System Settings Updated", 
                request.user, 
                details=f"Auto Approval Mode set to {auto_approval}"
            )
            response_data["auto_approval_mode"] = setting.value == 'true'

        if auto_routing is not None:
            setting, created = SystemSetting.objects.update_or_create(
                key='auto_routing_mode',
                defaults={'value': str(auto_routing).lower()}
            )
            log_activity(
                "System Settings Updated", 
                request.user, 
                details=f"Auto Routing Mode set to {auto_routing}"
            )
            response_data["auto_routing_mode"] = setting.value == 'true'

        if admin_absent_mode is not None:
            setting, created = SystemSetting.objects.update_or_create(
                key='admin_absent_mode',
                defaults={'value': str(admin_absent_mode).lower()}
            )
            log_activity(
                "System Settings Updated", 
                request.user, 
                details=f"Admin Absent Mode set to {admin_absent_mode}"
            )
            response_data["admin_absent_mode"] = setting.value == 'true'

        if admin_absent_mode_type is not None:
            setting, created = SystemSetting.objects.update_or_create(
                key='admin_absent_mode_type',
                defaults={'value': str(admin_absent_mode_type).lower()}
            )
            log_activity(
                "System Settings Updated", 
                request.user, 
                details=f"Admin Absent Mode Type set to {admin_absent_mode_type}"
            )
            response_data["admin_absent_mode_type"] = setting.value

        if allow_direct_forwarding is not None:
            setting, created = SystemSetting.objects.update_or_create(
                key='allow_direct_forwarding',
                defaults={'value': str(allow_direct_forwarding).lower()}
            )
            log_activity(
                "System Settings Updated", 
                request.user, 
                details=f"Allow Direct Forwarding set to {allow_direct_forwarding}"
            )
            response_data["allow_direct_forwarding"] = setting.value == 'true'

        if admin_status is not None:
            clean_status = str(admin_status).lower().strip()
            if clean_status in ['online', 'offline', 'away']:
                setting, created = SystemSetting.objects.update_or_create(
                    key='admin_status',
                    defaults={'value': clean_status}
                )
                log_activity(
                    "Admin Status Updated", 
                    request.user, 
                    details=f"Admin Status set to {clean_status.capitalize()}"
                )
                response_data["admin_status"] = setting.value
            else:
                return Response({"detail": "Invalid status value. Choose online, offline, or away."}, status=status.HTTP_400_BAD_REQUEST)

        if admin_mobile_number is not None:
            setting, created = SystemSetting.objects.update_or_create(
                key='admin_mobile_number',
                defaults={'value': str(admin_mobile_number).strip()}
            )
            log_activity(
                "System Settings Updated", 
                request.user, 
                details=f"Admin Mobile Number set to {admin_mobile_number}"
            )
            response_data["admin_mobile_number"] = setting.value

        if response_data:
            return Response(response_data)
        
        return Response({"detail": "No settings provided."}, status=status.HTTP_400_BAD_REQUEST)

class PermissionViewSet(viewsets.ModelViewSet):
    queryset = PermissionSetting.objects.all()
    serializer_class = PermissionSettingSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        if self.request.user.role != UserRole.ADMIN:
            return PermissionSetting.objects.none()
        return PermissionSetting.objects.all()

    @action(detail=False, methods=['post'], url_path='toggle-officer')
    def toggle_officer(self, request):
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Access Denied"}, status=status.HTTP_403_FORBIDDEN)

        officer_id = request.data.get('officer_id')
        allowed = request.data.get('allowed') # True/False
        bypass_limit = request.data.get('bypass_daily_limit') # True/False
        extra_requests_limit = request.data.get('extra_requests_limit')
        bypass_days = request.data.get('bypass_days')

        if officer_id is None:
            return Response({"detail": "officer_id is required."}, status=status.HTTP_400_BAD_REQUEST)

        if allowed is None and bypass_limit is None:
            return Response({"detail": "Either allowed or bypass_daily_limit is required."}, status=status.HTTP_400_BAD_REQUEST)

        officer = get_object_or_404(User, id=officer_id, role=UserRole.OFFICER)
        
        defaults = {}
        if allowed is not None:
            defaults['direct_forward_allowed'] = allowed
        if bypass_limit is not None:
            defaults['bypass_daily_limit'] = bypass_limit
            defaults['bypass_requested'] = False
            if bypass_limit:
                try:
                    ext_limit = int(extra_requests_limit) if extra_requests_limit is not None else 5
                except ValueError:
                    ext_limit = 5
                try:
                    days = int(bypass_days) if bypass_days is not None else 1
                except ValueError:
                    days = 1
                defaults['extra_requests_limit'] = ext_limit
                defaults['bypass_expiry_date'] = timezone.now() + timezone.timedelta(days=days)
            else:
                defaults['extra_requests_limit'] = 0
                defaults['bypass_expiry_date'] = None

        perm, created = PermissionSetting.objects.update_or_create(
            officer=officer,
            defaults=defaults
        )

        if allowed is not None:
            log_activity(
                "Officer Permission Updated", 
                request.user, 
                details=f"Direct Forward Permission for {officer.username} set to {allowed}"
            )
            create_notification(
                officer,
                "Direct Forward Permission Updated",
                f"Your permission to send requests directly to TSPs has been " + ("GRANTED" if allowed else "REVOKED") + " by admin."
            )

        if bypass_limit is not None:
            log_activity(
                "Officer Permission Updated", 
                request.user, 
                details=f"Bypass Daily Limit Permission for {officer.username} set to {bypass_limit}"
            )
            create_notification(
                officer,
                "Request Limit Permission Updated",
                f"Your permission to bypass the daily request limit has been " + ("GRANTED" if bypass_limit else "REVOKED") + " by admin."
            )

        return Response(PermissionSettingSerializer(perm).data)

    @action(detail=False, methods=['post'], url_path='request-bypass')
    def request_bypass(self, request):
        if request.user.role != UserRole.OFFICER:
            return Response({"detail": "Only field officers can request limit bypass."}, status=status.HTTP_403_FORBIDDEN)
            
        perm, created = PermissionSetting.objects.get_or_create(
            officer=request.user,
            defaults={'bypass_requested': True}
        )
        if not created:
            perm.bypass_requested = True
            perm.save()
            
        # Notify admins
        admins = User.objects.filter(role=UserRole.ADMIN)
        for admin in admins:
            create_notification(
                admin,
                "Bypass Daily Limit Request",
                f"Field Officer {request.user.username} has requested permission to bypass their daily limit."
            )
            
        # Log activity
        log_activity(
            "Bypass Requested",
            request.user,
            details=f"Officer {request.user.username} requested daily limit bypass permission."
        )
        
        # Save user state changes to Supabase mirror
        from api.supabase_db import async_sync_user
        async_sync_user(request.user)
        
        return Response({"detail": "Bypass request sent to admin."})

class NotificationViewSet(viewsets.ModelViewSet):
    serializer_class = SystemNotificationSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        return SystemNotification.objects.filter(user=self.request.user).order_by('-created_at')[:100]

    @action(detail=False, methods=['post'], url_path='mark-all-read')
    def mark_all_read(self, request):
        SystemNotification.objects.filter(user=request.user, is_read=False).update(is_read=True)
        return Response({"status": "all read"})

class ActivityLogViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class = ActivityLogSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        user = self.request.user
        if user.role != UserRole.ADMIN:
            return ActivityLog.objects.filter(user=user).select_related('user', 'request').order_by('-timestamp')[:100]
        return ActivityLog.objects.all().select_related('user', 'request').order_by('-timestamp')[:100]

# View to download reports
class ExportReportView(views.APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Access Denied"}, status=status.HTTP_403_FORBIDDEN)

        export_format = request.query_params.get('export_format', 'excel') # 'excel' or 'pdf'
        
        # Filter parameters
        status_filter = request.query_params.get('status')
        tsp_filter = request.query_params.get('tsp')
        officer_filter = request.query_params.get('officer')

        requests_qs = Request.objects.all().order_by('-created_at')
        if status_filter:
            requests_qs = requests_qs.filter(status=status_filter)
        if tsp_filter:
            requests_qs = requests_qs.filter(tsp_id=tsp_filter)
        if officer_filter:
            requests_qs = requests_qs.filter(officer_id=officer_filter)

        if export_format == 'pdf':
            return self.export_pdf(requests_qs)
        else:
            return self.export_excel(requests_qs)

    def export_excel(self, queryset):
        data = []
        for req in queryset:
            resp_details = ""
            resp_time = ""
            if req.tsp_response:
                resp_details = req.tsp_response.details
                resp_time = req.tsp_response.timestamp.strftime('%d/%m/%Y %I:%M %p')
                
            data.append({
                'Request ID': req.id,
                'Ticket ID': req.ticket_id or f"TSPTKT-{req.id:06d}",
                'Station Name': req.station_name or "",
                'CR Number': req.cr_no or "",
                'Mobile Number': req.mobile_number,
                'TSP': req.tsp.name,
                'Reason': req.reason,
                'Status': req.get_status_display(),
                'Field Officer Name': req.officer.get_full_name().strip() or req.officer.username,
                'Admin Remarks': req.remarks or "",
                'Auto Approved': 'Yes' if req.is_auto_approved else 'No',
                'Created At': req.created_at.strftime('%d/%m/%Y %I:%M %p'),
                'TSP Response Details': resp_details,
                'TSP Response Date & Time': resp_time
            })

        df = pd.DataFrame(data)
        
        # Write to memory buffer
        buffer = io.BytesIO()
        with pd.ExcelWriter(buffer, engine='openpyxl') as writer:
            df.to_excel(writer, index=False, sheet_name='Requests Report')
            
        buffer.seek(0)
        
        response = HttpResponse(
            buffer.getvalue(),
            content_type='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        )
        response['Content-Disposition'] = f'attachment; filename="sms_forwarding_report_{timezone.now().strftime("%Y%m%d_%H%M%S")}.xlsx"'
        return response

    def export_pdf(self, queryset):
        # Create a PDF using ReportLab
        buffer = io.BytesIO()
        doc = SimpleDocTemplate(
            buffer,
            pagesize=letter,
            rightMargin=36, leftMargin=36, topMargin=54, bottomMargin=54
        )
        
        styles = getSampleStyleSheet()
        
        # Custom styles
        title_style = ParagraphStyle(
            name='TitleStyle',
            fontName='Helvetica-Bold',
            fontSize=16,
            leading=20,
            textColor=colors.HexColor('#0F172A'),
            alignment=1, # Center
            spaceAfter=15
        )
        
        meta_style = ParagraphStyle(
            name='MetaStyle',
            fontName='Helvetica',
            fontSize=10,
            leading=14,
            textColor=colors.HexColor('#64748B'),
            alignment=1,
            spaceAfter=30
        )
        
        table_text = ParagraphStyle(
            name='TableText',
            fontName='Helvetica',
            fontSize=8,
            leading=10,
            textColor=colors.HexColor('#334155')
        )
        
        table_header = ParagraphStyle(
            name='TableHeader',
            fontName='Helvetica-Bold',
            fontSize=9,
            leading=11,
            textColor=colors.white
        )

        elements = []
        
        elements.append(Paragraph("SMS Forwarding & TSP Information Management System", title_style))
        elements.append(Paragraph(f"Exported Report - Generated on: {timezone.now().strftime('%Y-%m-%d %H:%M:%S')}", meta_style))
        
        # Build Table data
        # Headers: ID, Mobile, TSP, Officer, Status, Created At, TSP Response Date & Time
        table_data = [[
            Paragraph("ID", table_header),
            Paragraph("Mobile Number", table_header),
            Paragraph("TSP", table_header),
            Paragraph("Field Officer Name", table_header),
            Paragraph("Status", table_header),
            Paragraph("Created At", table_header),
            Paragraph("TSP Response Date & Time", table_header)
        ]]
        
        # ReportLab table sizes
        # Available width is 612 - 72 = 540
        col_widths = [25, 75, 55, 95, 90, 100, 100]
        
        for req in queryset:
            resp_time = req.tsp_response.timestamp.strftime('%d/%m/%Y %I:%M %p') if req.tsp_response else ""
            table_data.append([
                Paragraph(str(req.id), table_text),
                Paragraph(req.mobile_number, table_text),
                Paragraph(req.tsp.name, table_text),
                Paragraph(req.officer.get_full_name().strip() or req.officer.username, table_text),
                Paragraph(req.get_status_display(), table_text),
                Paragraph(req.created_at.strftime('%d/%m/%Y %I:%M %p'), table_text),
                Paragraph(resp_time, table_text)
            ])
            
        t = Table(table_data, colWidths=col_widths, repeatRows=1)
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor('#1E293B')),
            ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
            ('VALIGN', (0, 0), (-1, -1), 'TOP'),
            ('BOTTOMPADDING', (0, 0), (-1, 0), 6),
            ('TOPPADDING', (0, 0), (-1, 0), 6),
            ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.HexColor('#F8FAFC'), colors.white]),
            ('GRID', (0, 0), (-1, -1), 0.5, colors.HexColor('#CBD5E1')),
            ('TOPPADDING', (0, 1), (-1, -1), 5),
            ('BOTTOMPADDING', (0, 1), (-1, -1), 5),
        ]))
        
        elements.append(t)
        doc.build(elements)
        
        buffer.seek(0)
        response = HttpResponse(buffer.getvalue(), content_type='application/pdf')
        response['Content-Disposition'] = f'attachment; filename="sms_forwarding_report_{timezone.now().strftime("%Y%m%d_%H%M%S")}.pdf"'
        return response

class FieldOfficerListView(views.APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Access Denied"}, status=status.HTTP_403_FORBIDDEN)
        
        # Use select_related to fetch permissions in a single JOIN — avoids N+1 queries
        officers = User.objects.filter(role=UserRole.OFFICER).select_related('permission')
        # Bulk-create missing PermissionSetting rows in one query instead of a loop
        officer_ids_with_perms = set(
            PermissionSetting.objects.filter(officer__in=officers).values_list('officer_id', flat=True)
        )
        missing = [PermissionSetting(officer=o) for o in officers if o.id not in officer_ids_with_perms]
        if missing:
            PermissionSetting.objects.bulk_create(missing, ignore_conflicts=True)

        serializer = UserSerializer(officers, many=True)
        return Response(serializer.data)

    def post(self, request):
        try:
            if request.user.role != UserRole.ADMIN:
                return Response({"detail": "Access Denied"}, status=status.HTTP_403_FORBIDDEN)
            
            username = request.data.get('username')
            password = request.data.get('password')
            first_name = request.data.get('first_name', '')
            last_name = request.data.get('last_name', '')
            mobile_number = request.data.get('mobile_number', '')
            station_name = request.data.get('station_name', '')
            
            if not username or not password:
                return Response({"detail": "Username and password are required."}, status=status.HTTP_400_BAD_REQUEST)
                
            email = request.data.get('email')
            if not email:
                email = f"{username}@smstsp.com"
            
            # Verify username uniqueness
            if User.objects.filter(username=username).exists():
                return Response({"detail": "Username is already taken. Please choose another."}, status=status.HTTP_400_BAD_REQUEST)
                
            # Create user
            officer = User.objects.create_user(
                username=username,
                email=email,
                password=password,
                first_name=first_name,
                last_name=last_name,
                role=UserRole.OFFICER,
                mobile_number=mobile_number,
                station_name=station_name
            )
            
            # Create permission setting
            PermissionSetting.objects.get_or_create(officer=officer)
            
            log_activity(
                "Field Officer Created", 
                request.user, 
                details=f"Created Field Officer: {officer.username} ({officer.email})"
            )
            
            return Response(UserSerializer(officer).data, status=status.HTTP_201_CREATED)
        except Exception as e:
            import traceback
            return Response({
                "detail": f"CRASH: {str(e)}", 
                "traceback": traceback.format_exc()
            }, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

class ChatMessageViewSet(viewsets.ModelViewSet):
    queryset = ChatMessage.objects.all().order_by('timestamp')
    serializer_class = ChatMessageSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        user = self.request.user
        request_id = self.request.query_params.get('request_id')
        
        # Filter by request if provided
        qs = ChatMessage.objects.select_related('sender', 'receiver')
        if request_id:
            qs = qs.filter(request_id=request_id)
            
        if user.role == UserRole.ADMIN:
            return qs.order_by('timestamp')
        elif user.role == UserRole.OFFICER:
            return qs.filter(Q(sender=user) | Q(receiver=user)).order_by('timestamp')
        elif user.role == UserRole.TSP:
            return qs.filter(Q(sender=user) | Q(receiver=user)).order_by('timestamp')
            
        return ChatMessage.objects.none()

    def perform_create(self, serializer):
        user = self.request.user
        request_obj = serializer.validated_data.get('request')
        receiver = serializer.validated_data.get('receiver')
        
        # Auto-fill receiver if missing
        if not receiver and request_obj:
            if user.role == UserRole.OFFICER:
                admin_user = User.objects.filter(role=UserRole.ADMIN).first()
                receiver = admin_user
            elif user.role == UserRole.ADMIN:
                receiver = request_obj.officer

        if not receiver:
            # Fallback receiver (first admin)
            admin_user = User.objects.filter(role=UserRole.ADMIN).first()
            receiver = admin_user

        if not receiver:
            raise serializers.ValidationError("Receiver must be specified.")

        msg = serializer.save(sender=user, receiver=receiver)
        
        # Save to file database
        save_chat_to_file(msg.id, ChatMessageSerializer(msg).data)

class TSPResponseViewSet(viewsets.ModelViewSet):
    queryset = TSPResponse.objects.all().order_by('-created_at')
    serializer_class = TSPResponseSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        user = self.request.user
        if user.role == UserRole.ADMIN:
            # Background poller handles SMS polling — no need to trigger here
            return TSPResponse.objects.all().order_by('-created_at')
        elif user.role == UserRole.TSP:
            if user.tsp_provider:
                return TSPResponse.objects.filter(tsp_provider__icontains=user.tsp_provider.name).order_by('-created_at')
        elif user.role == UserRole.OFFICER:
            return TSPResponse.objects.filter(request__officer=user, status='Sent to Officer').order_by('-created_at')
        return TSPResponse.objects.none()

    def perform_create(self, serializer):
        user = self.request.user
        resp = serializer.save(created_by=user, submitted_by=user)
        save_response_to_queue(resp.id, TSPResponseSerializer(resp).data, resp.tsp_provider)
        log_activity("TSP Response Created", user, request=resp.request, details=f"Mobile: {resp.mobile_number}, TSP: {resp.tsp_provider}")

    def perform_update(self, serializer):
        resp = serializer.save()
        save_response_to_queue(resp.id, TSPResponseSerializer(resp).data, resp.tsp_provider)
        log_activity("TSP Response Updated", self.request.user, request=resp.request, details=f"Mobile: {resp.mobile_number}, TSP: {resp.tsp_provider}")

    @action(detail=True, methods=['post'], url_path='send-to-officer')
    def send_to_officer(self, request, pk=None):
        resp = self.get_object()
        # [DISABLED] Allow forwarding of any responses (even acknowledgments)
        # if resp.subscriber_status == 'Under Process':
        #     return Response(
        #         {"detail": "Acknowledgment responses cannot be forwarded to the officer. Please wait for the final subscriber details response from the TSP."},
        #         status=status.HTTP_400_BAD_REQUEST
        #     )
        resp.status = 'Sent to Officer'
        resp.response_date = timezone.now()
        resp.save()
        
        save_response_to_queue(resp.id, TSPResponseSerializer(resp).data, resp.tsp_provider)

        req = resp.request
        if req:
            was_already_completed = req.status == RequestStatus.COMPLETED

            formatted_details = (
                f"Subscriber Status: {resp.subscriber_status}\n"
                f"Circle/State: {resp.circle}\n"
                f"Activation Date: {resp.activation_date.strftime('%Y-%m-%d') if resp.activation_date else 'N/A'}\n"
                f"Additional Notes: {resp.additional_notes}"
            )

            req.status = RequestStatus.COMPLETED
            req.admin_status = 'Completed'
            if req.response:
                if resp.details not in req.response:
                    req.response = f"{req.response}\n\n[Update]: {resp.details}"
            else:
                req.response = resp.details
            req.response_date = timezone.now()
            req.save()

            # ── Mirror to Supabase (Always sync on forward response) ───────────
            async_sync_user(request.user)
            async_save_request(req)
            async_save_admin_forward_response(req, resp, request.user)
            async_log_status(
                req, request.user,
                action_type="Admin Forwarded Response To Officer",
                details=formatted_details,
                old_status="Response_Received_From_TSP",
                new_status="Forwarded_To_Officer",
            )
            # ──────────────────────────────────────────────────────────────────

            # Only create status log and send notifications if not already completed
            if not was_already_completed:
                RequestStatusLog.objects.create(
                    request=req,
                    status=RequestStatus.COMPLETED,
                    changed_by=request.user,
                    remarks="TSP Response forwarded to Field Officer."
                )

                # Audit Log - Completed
                approval_time_str = req.created_at.strftime('%Y-%m-%d %H:%M:%S')
                response_time_str = timezone.now().strftime('%Y-%m-%d %H:%M:%S')
                admin_status_val = SystemSetting.objects.filter(key='admin_status').first()
                admin_status_str = admin_status_val.value.capitalize() if admin_status_val else 'Online'
                
                audit_details = (
                    f"Officer Name: {req.officer_name}\n"
                    f"Mobile Number: {req.mobile_number}\n"
                    f"Selected TSP: {req.tsp.name}\n"
                    f"Admin Status: {admin_status_str}\n"
                    f"Auto Approval Time: {approval_time_str if req.is_auto_approved else 'N/A (Manual Review)'}\n"
                    f"Response Time: {response_time_str}"
                )
                ActivityLog.objects.create(
                    action="Audit Log - Completed",
                    user=request.user,
                    request=req,
                    details=audit_details
                )

                log_activity("Response Sent to Officer", request.user, request=req, details=formatted_details)

                create_notification(
                    req.officer,
                    "TSP Request Completed",
                    f"Admin has sent the TSP response for request #{req.id} ({req.mobile_number})."
                )

                msg_text = (
                    f"✅ **Request Completed & Sent to Officer** ✅\n"
                    f"📱 **Mobile:** {resp.mobile_number}\n"
                    f"📶 **TSP Name:** {resp.tsp_provider}\n"
                    f"📋 **Response Details:** {resp.details}\n"
                    f"📋 **Subscriber Status:** {resp.subscriber_status}\n"
                    f"📍 **Circle/State:** {resp.circle}\n"
                    f"📅 **Activation Date:** {resp.activation_date.strftime('%Y-%m-%d') if resp.activation_date else 'N/A'}\n"
                    f"📝 **Additional Notes:** {resp.additional_notes or 'None'}"
                )
                chat_msg = ChatMessage.objects.create(
                    sender=request.user,
                    receiver=req.officer,
                    request=req,
                    message=msg_text
                )
                save_chat_to_file(chat_msg.id, ChatMessageSerializer(chat_msg).data)

            # Always sync request file to reflect latest state
            save_request_to_file(req.id, RequestSerializer(req).data)

        return Response(TSPResponseSerializer(resp).data)

class DatabaseBrowserView(views.APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Access Denied"}, status=status.HTTP_403_FORBIDDEN)
        
        data = get_db_file_structure()
        return Response(data)

class SMSLogViewSet(viewsets.ModelViewSet):
    queryset = SMSLog.objects.all().order_by('-timestamp')
    serializer_class = SMSLogSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        user = self.request.user
        if user.role == UserRole.ADMIN:
            return SMSLog.objects.all().select_related('request').order_by('-timestamp')[:100]
        return SMSLog.objects.none()


class PollSMSView(views.APIView):
    """
    Admin-only endpoint to manually trigger a TextBee SMS poll.
    Bypasses the 10-second cache so the admin can force-check immediately.
    Returns how many new SMS messages were processed.
    """
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request):
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Only admins can trigger SMS polling."}, status=status.HTTP_403_FORBIDDEN)

        api_key = getattr(settings, 'TEXTBEE_API_KEY', '')
        device_id = getattr(settings, 'TEXTBEE_DEVICE_ID', '')
        if not api_key or not device_id:
            return Response({"detail": "TextBee API key or Device ID not configured."}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        url = f"https://api.textbee.dev/api/v1/gateway/devices/{device_id}/get-received-sms"
        headers = {"x-api-key": api_key, "User-Agent": "Mozilla/5.0"}

        try:
            req_obj = urllib.request.Request(url, headers=headers, method='GET')
            with urllib.request.urlopen(req_obj, timeout=15) as response:
                res_data = json.loads(response.read().decode('utf-8'))
                messages = res_data.get('data', [])

            from api.file_db import try_mark_sms_as_processed
            processed_count = 0
            ack_count = 0

            for msg_data in messages:
                sms_id = msg_data.get('_id') or msg_data.get('id')
                if not sms_id:
                    continue
                sender = msg_data.get('sender', '')
                message = msg_data.get('message', '')
                received_at_str = msg_data.get('receivedAt', '')

                # Filter non-TSP senders early
                sender_clean = normalize_phone(sender)
                is_tsp_sender = False
                for tsp in TSPProvider.objects.filter(is_active=True):
                    if normalize_phone(tsp.mobile_number) == sender_clean:
                        is_tsp_sender = True
                        break

                # Atomic check-and-mark to prevent concurrency duplicates (e.g. between Poller and Webhook)
                if not try_mark_sms_as_processed(sms_id):
                    continue

                if not is_tsp_sender:
                    continue

                success = process_single_received_sms(sms_id, sender, message, received_at_str)
                if success:
                    processed_count += 1
                    if is_acknowledgment_message(message):
                        ack_count += 1

            # Reset the global poll timer so the background poller also re-fetches
            global LAST_POLL_TIME
            LAST_POLL_TIME = 0

            return Response({
                "detail": f"Poll complete. {processed_count} new SMS processed ({ack_count} acknowledgments, {processed_count - ack_count} responses).",
                "total_fetched": len(messages),
                "new_processed": processed_count,
            })

        except Exception as e:
            return Response({"detail": f"Error polling TextBee: {str(e)}"}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)


class TextBeeWebhookView(views.APIView):
    """
    Webhook endpoint that TextBee calls automatically when an SMS is received.
    No authentication required — TextBee does not send auth headers.
    Register this URL in the TextBee dashboard as the webhook URL:
        http://<your-server>/api/textbee-webhook/
    This gives REAL-TIME TSP response delivery instead of polling.
    """
    permission_classes = [permissions.AllowAny]

    def post(self, request):
        data = request.data
        print(f"[TEXTBEE WEBHOOK] Received webhook: {str(data)[:300]}")

        # TextBee sends: { "_id": "...", "sender": "...", "message": "...", "receivedAt": "..." }
        # or wraps it: { "data": { ... } }
        sms_data = data
        if 'data' in data and isinstance(data['data'], dict):
            sms_data = data['data']

        sms_id       = sms_data.get('_id') or sms_data.get('id') or f"webhook-{timezone.now().timestamp()}"
        sender       = sms_data.get('sender', '')
        message_body = sms_data.get('message', '') or sms_data.get('body', '')
        received_at  = sms_data.get('receivedAt', '') or timezone.now().isoformat()

        if not message_body:
            print("[TEXTBEE WEBHOOK] Empty message body — ignoring.")
            return Response({"detail": "Empty message ignored."}, status=200)

        # Atomic check-and-mark to prevent concurrency duplicates (e.g. between Poller and Webhook)
        from api.file_db import try_mark_sms_as_processed
        if not try_mark_sms_as_processed(sms_id):
            print(f"[TEXTBEE WEBHOOK] SMS {sms_id} already processed — skipping.")
            return Response({"detail": "Already processed."}, status=200)

        # Filter non-TSP senders early
        sender_clean = normalize_phone(sender)
        is_tsp_sender = False
        for tsp in TSPProvider.objects.filter(is_active=True):
            if normalize_phone(tsp.mobile_number) == sender_clean:
                is_tsp_sender = True
                break

        if not is_tsp_sender:
            print(f"[TEXTBEE WEBHOOK] Ignored non-TSP SMS {sms_id} from {sender}.")
            return Response({"detail": "Ignored non-TSP sender."}, status=200)

        print(f"[TEXTBEE WEBHOOK] Processing SMS {sms_id} from {sender}: {message_body[:100]}")
        try:
            success = process_single_received_sms(sms_id, sender, message_body, received_at)
            if success:
                # Reset poll timer so next background poll also skips already-processed IDs
                global LAST_POLL_TIME
                LAST_POLL_TIME = 0
                print(f"[TEXTBEE WEBHOOK] SMS {sms_id} processed successfully.")
            return Response({"detail": "Received and processed."}, status=200)
        except Exception as e:
            print(f"[TEXTBEE WEBHOOK] Error processing SMS {sms_id}: {e}")
            return Response({"detail": f"Error: {str(e)}"}, status=200)  # Return 200 so TextBee doesn't retry


class DashboardView(views.APIView):
    """
    Combined dashboard endpoint — returns ALL data needed for the initial
    dashboard load in a single request, eliminating 7+ sequential HTTP calls.
    """
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        return Response(get_dashboard_data(request.user, request))


class HealthCheckView(views.APIView):
    """
    Public health check endpoint.
    Used by the client to ping candidates and wake up the server.
    """
    permission_classes = [permissions.AllowAny]

    def get(self, request):
        return Response({"status": "ok"}, status=status.HTTP_200_OK)


# ──────────────────────────────────────────────────────────────
#  Password Reset Request — officer submits / admin manages
# ──────────────────────────────────────────────────────────────

class PasswordResetRequestView(views.APIView):
    """
    POST  /api/password-reset-request/
        No authentication needed — the officer is logged-out when they hit
        "Forgot password", so they submit their username + desired new password.
    """
    permission_classes = [permissions.AllowAny]

    def post(self, request):
        username = (request.data.get('username') or '').strip()
        new_password = (request.data.get('new_password') or '').strip()

        if not username or not new_password:
            return Response(
                {"detail": "username and new_password are required."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Verify the officer actually exists to avoid harvesting usernames
        if not User.objects.filter(username=username, role=UserRole.OFFICER).exists():
            return Response(
                {"detail": "No officer account found with that username."},
                status=status.HTTP_404_NOT_FOUND,
            )

        # Create (or update an existing Pending one) — only one active request at a time
        obj, created = PasswordResetRequest.objects.update_or_create(
            username=username,
            status='Pending',
            defaults={'requested_new_password': new_password},
        )

        # Notify all admins
        admins = User.objects.filter(role=UserRole.ADMIN)
        for admin in admins:
            create_notification(
                admin,
                "Password Reset Request",
                f"Officer '{username}' has requested a password reset. Review in the Admin panel.",
            )

        return Response(
            {"detail": "Your password reset request has been sent to the admin."},
            status=status.HTTP_201_CREATED,
        )


class PasswordResetAdminView(views.APIView):
    """
    GET   /api/password-reset-admin/           — list all pending/resolved requests
    POST  /api/password-reset-admin/           — approve or reject a specific request
        body: { "request_id": <int>, "action": "approve" | "reject" }
        If approved, the officer's password is updated to the requested value.
    """
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Access Denied."}, status=status.HTTP_403_FORBIDDEN)

        qs = PasswordResetRequest.objects.all().order_by('-created_at')
        serializer = PasswordResetRequestSerializer(qs, many=True)
        return Response(serializer.data)

    def post(self, request):
        if request.user.role != UserRole.ADMIN:
            return Response({"detail": "Access Denied."}, status=status.HTTP_403_FORBIDDEN)

        request_id = request.data.get('request_id')
        action = (request.data.get('action') or '').lower()  # 'approve' or 'reject'

        if not request_id or action not in ('approve', 'reject'):
            return Response(
                {"detail": "request_id and action ('approve'/'reject') are required."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        reset_req = get_object_or_404(PasswordResetRequest, id=request_id)

        if reset_req.status != 'Pending':
            return Response(
                {"detail": f"This request is already '{reset_req.status}'."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if action == 'approve':
            # Actually update the officer's password
            try:
                officer = User.objects.get(username=reset_req.username, role=UserRole.OFFICER)
            except User.DoesNotExist:
                return Response(
                    {"detail": "Officer account no longer exists."},
                    status=status.HTTP_404_NOT_FOUND,
                )

            officer.set_password(reset_req.requested_new_password)
            officer.save()

            reset_req.status = 'Approved'
            reset_req.save()

            create_notification(
                officer,
                "Password Reset Approved",
                "The admin has approved your password reset request. You may now log in with your new password.",
            )
            log_activity(
                "Password Reset Approved",
                request.user,
                details=f"Admin approved password reset for officer '{reset_req.username}'.",
            )
            return Response({"detail": f"Password for '{reset_req.username}' has been updated."})

        else:  # reject
            reset_req.status = 'Rejected'
            reset_req.save()

            try:
                officer = User.objects.get(username=reset_req.username, role=UserRole.OFFICER)
                create_notification(
                    officer,
                    "Password Reset Rejected",
                    "The admin has rejected your password reset request. Contact your admin for assistance.",
                )
            except User.DoesNotExist:
                pass

            log_activity(
                "Password Reset Rejected",
                request.user,
                details=f"Admin rejected password reset request for officer '{reset_req.username}'.",
            )
            return Response({"detail": f"Password reset request for '{reset_req.username}' has been rejected."})


