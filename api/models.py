# type: ignore
# mypy: ignore-errors
from django.db import models
from django.contrib.auth.models import AbstractUser
import uuid

class UserRole(models.TextChoices):
    ADMIN = 'ADMIN', 'Admin'
    OFFICER = 'OFFICER', 'Field Officer'
    TSP = 'TSP', 'TSP Representative'

class RequestStatus(models.TextChoices):
    PENDING = 'PENDING', 'Pending Admin Approval'
    APPROVED = 'APPROVED', 'Approved'
    PROCESSING = 'PROCESSING', 'Processing'
    REJECTED = 'REJECTED', 'Rejected'
    FORWARDED = 'FORWARDED', 'Forwarded to TSP'
    TSP_RESPONDED = 'TSP_RESPONDED', 'TSP Response Received'
    COMPLETED = 'COMPLETED', 'Forwarded to Officer'
    CLOSED = 'CLOSED', 'Closed'

class TSPProvider(models.Model):
    name = models.CharField(max_length=100, unique=True)
    code = models.CharField(max_length=20, unique=True)  # e.g., JIO, AIRTEL, BSNL, VI
    contact_email = models.EmailField()
    mobile_number = models.CharField(max_length=15, blank=True, default='')  # TSP outbound number (admin sends to this)
    inbound_number = models.CharField(max_length=15, blank=True, default='9844281875')  # Our inbound number (TSP sends SMS here)
    sms_template = models.TextField(blank=True, default='')  # Predefined SMS template format (e.g., Loc <Number>)
    is_default = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name

class User(AbstractUser):
    role = models.CharField(
        max_length=20,
        choices=UserRole.choices,
        default=UserRole.OFFICER
    )
    tsp_provider = models.ForeignKey(
        TSPProvider,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='representatives'
    )

    def __str__(self):
        return f"{self.username} ({self.role})"

class Request(models.Model):
    objects: models.Manager['Request'] = models.Manager()
    tsp_responses: models.Manager['TSPResponse']
    cr_no = models.CharField(max_length=50, blank=True, default='')
    station_name = models.CharField(max_length=150, blank=True, default='')
    location = models.CharField(max_length=100, blank=True, default='')
    mobile_number = models.CharField(max_length=15)
    tsp = models.ForeignKey(TSPProvider, on_delete=models.CASCADE, related_name='requests')
    reason = models.TextField(blank=True, default='')
    subject = models.CharField(max_length=200, blank=True, default='')
    message = models.TextField(blank=True, default='')
    ticket_id = models.CharField(max_length=50, blank=True, default='')
    status = models.CharField(
        max_length=30,
        choices=RequestStatus.choices,
        default=RequestStatus.PENDING
    )
    officer = models.ForeignKey(User, on_delete=models.CASCADE, related_name='created_requests')
    officer_name = models.CharField(max_length=150, blank=True, default='')
    remarks = models.TextField(blank=True, default='')
    admin_remarks = models.TextField(blank=True, null=True)
    is_auto_approved = models.BooleanField(default=False)
    is_absent_approved = models.BooleanField(default=False)
    is_direct_forwarded = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    forwarded_at = models.DateTimeField(null=True, blank=True)
    response = models.TextField(blank=True, default='')
    response_date = models.DateTimeField(null=True, blank=True)
    admin_status = models.CharField(max_length=50, default='Pending')

    def save(self, *args, **kwargs):
        is_new = self.pk is None
        super().save(*args, **kwargs)
        if is_new and not self.ticket_id:
            self.ticket_id = f"TSPTKT-{self.id:06d}"
            super().save(update_fields=['ticket_id'])

    @property
    def tsp_response(self):
        resps = list(self.tsp_responses.order_by('-id'))
        return resps[0] if resps else None

    def __str__(self):
        return f"Req #{self.id} - {self.mobile_number} ({self.status})"

class SMSLog(models.Model):
    request = models.ForeignKey(Request, on_delete=models.CASCADE, related_name='sms_logs')
    direction = models.CharField(max_length=10, choices=[('SENT', 'Sent'), ('RECEIVED', 'Received')])
    operator = models.CharField(max_length=50)
    tsp_number = models.CharField(max_length=15)
    message = models.TextField()
    timestamp = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.direction} - {self.operator} ({self.tsp_number}) at {self.timestamp}"

class ChatMessage(models.Model):
    sender = models.ForeignKey(User, on_delete=models.CASCADE, related_name='sent_messages')
    receiver = models.ForeignKey(User, on_delete=models.CASCADE, related_name='received_messages')
    request = models.ForeignKey(Request, on_delete=models.CASCADE, related_name='chat_messages', null=True, blank=True)
    message = models.TextField()
    timestamp = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Msg from {self.sender.username} to {self.receiver.username} at {self.timestamp}"

class RequestStatusLog(models.Model):
    request = models.ForeignKey(Request, on_delete=models.CASCADE, related_name='status_logs')
    status = models.CharField(max_length=30, choices=RequestStatus.choices)
    changed_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True)
    remarks = models.TextField(blank=True, null=True)
    timestamp = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Log #{self.id} - Req #{self.request.id} -> {self.status}"

class TSPResponse(models.Model):
    request = models.ForeignKey(Request, on_delete=models.CASCADE, related_name='tsp_responses', null=True, blank=True)
    details = models.TextField(blank=True, default='')  # The information/details returned by the TSP
    submitted_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, related_name='submitted_responses')
    timestamp = models.DateTimeField(auto_now_add=True)

    # New fields
    mobile_number = models.CharField(max_length=15, blank=True, default='')
    tsp_provider = models.CharField(max_length=100, blank=True, default='') # Airtel, Jio, BSNL, Vodafone Idea (Vi)
    subscriber_status = models.CharField(max_length=50, blank=True, default='')
    circle = models.CharField(max_length=100, blank=True, default='')
    activation_date = models.DateField(null=True, blank=True)
    additional_notes = models.TextField(blank=True, default='')
    response_date = models.DateTimeField(null=True, blank=True)
    status = models.CharField(max_length=50, default='Pending') # Pending, Received, Reviewed, Sent to Officer
    
    created_by = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, related_name='created_responses')
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Response to Req #{self.request.id if self.request else 'None'} ({self.tsp_provider})"

class PermissionSetting(models.Model):
    officer = models.OneToOneField(User, on_delete=models.CASCADE, related_name='permission')
    direct_forward_allowed = models.BooleanField(default=False)
    bypass_daily_limit = models.BooleanField(default=False)
    bypass_requested = models.BooleanField(default=False)
    extra_requests_limit = models.IntegerField(default=0)
    bypass_expiry_date = models.DateTimeField(null=True, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"Perm: {self.officer.username} - Direct: {self.direct_forward_allowed}, Bypass Limit: {self.bypass_daily_limit}, Extra: {self.extra_requests_limit}"

class SystemNotification(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='notifications')
    title = models.CharField(max_length=200)
    message = models.TextField()
    is_read = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Notification to {self.user.username}: {self.title}"

class ActivityLog(models.Model):
    action = models.CharField(max_length=100)
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True)
    request = models.ForeignKey(Request, on_delete=models.SET_NULL, null=True, blank=True)
    details = models.TextField(blank=True, null=True)
    timestamp = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"Activity: {self.action} by {self.user.username if self.user else 'System'}"

class SystemSetting(models.Model):
    key = models.CharField(max_length=50, unique=True)
    value = models.CharField(max_length=200)

    def __str__(self):
        return f"{self.key}: {self.value}"

class AdminForwardRequest(models.Model):
    request = models.ForeignKey(Request, on_delete=models.CASCADE, related_name='forwarded_records')
    admin = models.ForeignKey(User, on_delete=models.CASCADE, related_name='forwarded_by_admin')
    tsp = models.ForeignKey(TSPProvider, on_delete=models.CASCADE, related_name='forwarded_to_tsp', null=True, blank=True)
    forwarded_message = models.TextField(blank=True, default='')
    forwarded_at = models.DateTimeField(auto_now_add=True)
    status = models.CharField(max_length=30, default='Forwarded')

    def __str__(self):
        return f"Forward #{self.id} for Req #{self.request.id} to {self.tsp.name if self.tsp else 'Unknown'}"


class LoginDetail(models.Model):
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, related_name='login_details')
    username = models.CharField(max_length=150)
    role = models.CharField(max_length=20)
    ip_address = models.CharField(max_length=45, blank=True, default='')
    user_agent = models.TextField(blank=True, default='')
    login_time = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.username} ({self.role}) logged in at {self.login_time}"


class TspSetting(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    tsp_name = models.CharField(max_length=100, unique=True)
    forward_number = models.CharField(max_length=15, blank=True, default='')
    sms_template = models.TextField(blank=True, default='')
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = 'tsp_settings'

    def __str__(self):
        return f"{self.tsp_name} Setting"



