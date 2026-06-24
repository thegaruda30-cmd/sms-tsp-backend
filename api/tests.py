# type: ignore
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APITestCase
from api.models import User, TSPProvider, Request, RequestStatus, PermissionSetting, SystemSetting, UserRole

class SMSSystemTests(APITestCase):

    def setUp(self):
        # Create TSPs
        self.jio = TSPProvider.objects.create(name="Jio", code="JIO", contact_email="jio@test.com")
        
        # Create Users
        self.admin = User.objects.create_user(username="admin_test", password="password123", role=UserRole.ADMIN)
        self.officer = User.objects.create_user(username="officer_test", password="password123", role=UserRole.OFFICER)
        self.tsp_rep = User.objects.create_user(
            username="tsp_test", password="password123", role=UserRole.TSP, tsp_provider=self.jio
        )

        # Create settings
        SystemSetting.objects.create(key='auto_approval_mode', value='false')
        SystemSetting.objects.create(key='auto_routing_mode', value='false')

        # Create default permissions
        PermissionSetting.objects.create(officer=self.officer, direct_forward_allowed=False)

    def test_login(self):
        url = reverse('login')
        data = {'username': 'officer_test', 'password': 'password123'}
        response = self.client.post(url, data, format='json')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn('token', response.data)
        self.assertEqual(response.data['user']['role'], 'OFFICER')

    def test_create_request_approval_required(self):
        # Login as officer
        self.client.force_authenticate(user=self.officer)
        
        url = reverse('request-list')
        data = {
            'mobile_number': '9876543210',
            'tsp': self.jio.id,
            'reason': 'Investigation case #123'
        }
        response = self.client.post(url, data, format='json')
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        
        # Verify status is PENDING (since auto approval is false and officer has no direct forward perm)
        req = Request.objects.get(id=response.data['id'])
        self.assertEqual(req.status, RequestStatus.PENDING)
        self.assertFalse(req.is_auto_approved)

    def test_create_request_direct_forward_permission(self):
        # Update officer perm to direct forward
        perm = PermissionSetting.objects.get(officer=self.officer)
        perm.direct_forward_allowed = True
        perm.save()

        # Login as officer
        self.client.force_authenticate(user=self.officer)
        
        url = reverse('request-list')
        data = {
            'mobile_number': '9876543210',
            'tsp': self.jio.id,
            'reason': 'Emergency trace'
        }
        response = self.client.post(url, data, format='json')
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        
        # Verify status is FORWARDED immediately
        req = Request.objects.get(id=response.data['id'])
        self.assertEqual(req.status, RequestStatus.FORWARDED)
        self.assertTrue(req.is_auto_approved)

    def test_admin_review(self):
        # Create a pending request
        req = Request.objects.create(
            mobile_number="9876543210", tsp=self.jio, reason="Test", officer=self.officer, status=RequestStatus.PENDING
        )
        
        # Login as admin
        self.client.force_authenticate(user=self.admin)
        
        url = reverse('request-admin-review', args=[req.id])
        
        # Approve request
        data = {'action': 'APPROVE', 'remarks': 'Looks valid'}
        response = self.client.post(url, data, format='json')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        
        # Check that request gets forwarded to TSP
        req.refresh_from_db()
        self.assertEqual(req.status, RequestStatus.FORWARDED)
        self.assertEqual(req.remarks, 'Looks valid')

    def test_tsp_respond_and_admin_complete(self):
        # Create a forwarded request
        req = Request.objects.create(
            mobile_number="9876543210", tsp=self.jio, reason="Test", officer=self.officer, status=RequestStatus.FORWARDED
        )
        
        # Login as TSP rep and submit a real data response
        self.client.force_authenticate(user=self.tsp_rep)
        url_tsp = reverse('request-tsp-respond', args=[req.id])
        data_tsp = {'details': 'Owner: John Doe, Status: Active'}
        response_tsp = self.client.post(url_tsp, data_tsp, format='json')
        self.assertEqual(response_tsp.status_code, status.HTTP_200_OK)
        
        req.refresh_from_db()
        # FIX: After TSP responds, status must be TSP_RESPONDED (not COMPLETED).
        # Admin must review and explicitly forward it to the officer.
        self.assertEqual(req.status, RequestStatus.TSP_RESPONDED)
        self.assertEqual(req.admin_status, 'SMS Response Received')
        self.assertEqual(req.tsp_response.details, 'Owner: John Doe, Status: Active')
        # TSPResponse should be 'Received' so admin sees it in TSP Replies panel
        self.assertEqual(req.tsp_response.status, 'Received')
        
        # Login as admin to explicitly forward the response to officer
        self.client.force_authenticate(user=self.admin)
        url_admin = reverse('request-admin-complete', args=[req.id])
        data_admin = {'remarks': 'Forwarded details to you.'}
        response_admin = self.client.post(url_admin, data_admin, format='json')
        self.assertEqual(response_admin.status_code, status.HTTP_200_OK)
        
        req.refresh_from_db()
        # After admin completes, status must be COMPLETED
        self.assertEqual(req.status, RequestStatus.COMPLETED)
        self.assertEqual(req.remarks, 'Forwarded details to you.')

    def test_inbound_sms_acknowledgment_keeps_status_processing(self):
        # Create a forwarded request
        req = Request.objects.create(
            mobile_number="9876543210", tsp=self.jio, reason="Test", officer=self.officer, status=RequestStatus.FORWARDED
        )
        
        # Login as Admin
        self.client.force_authenticate(user=self.admin)
        url = reverse('request-tsp-sms-response', args=[req.id])
        
        # Post acknowledgment SMS
        data = {
            'from_number': '1234567890',
            'inbound_number': '9844281875',
            'sms_body': 'Okey we will inform soon'
        }
        response = self.client.post(url, data, format='json')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        
        req.refresh_from_db()
        # Verify status is TSP_RESPONDED even for acknowledgment messages
        self.assertEqual(req.status, RequestStatus.TSP_RESPONDED)
        self.assertEqual(req.admin_status, 'SMS Response Received')
        
        # Verify that TSPResponse is created for the acknowledgment
        self.assertTrue(req.tsp_responses.exists())
        tsp_resp = req.tsp_responses.first()
        assert tsp_resp is not None
        self.assertEqual(tsp_resp.details, 'Okey we will inform soon')
        self.assertEqual(tsp_resp.status, 'Received')
        self.assertEqual(tsp_resp.subscriber_status, 'Unknown')
        
        # Post actual subscriber info later
        data_actual = {
            'from_number': '1234567890',
            'inbound_number': '9844281875',
            'sms_body': 'Subscriber Status: Active\nCircle/State: Karnataka\nActivation Date: 2026-06-13'
        }
        response_actual = self.client.post(url, data_actual, format='json')
        self.assertEqual(response_actual.status_code, status.HTTP_200_OK)
        
        req.refresh_from_db()
        # Verify status now changes to TSP_RESPONDED
        self.assertEqual(req.status, RequestStatus.TSP_RESPONDED)
        self.assertEqual(req.admin_status, 'SMS Response Received')

    def test_export_reports(self):
        # Login as admin
        self.client.force_authenticate(user=self.admin)
        url = reverse('export-reports')
        
        # Test Excel download
        response_excel = self.client.get(url, {'export_format': 'excel'})
        self.assertEqual(response_excel.status_code, status.HTTP_200_OK)
        self.assertTrue(response_excel.has_header('Content-Disposition'))
        
        # Test PDF download
        response_pdf = self.client.get(url, {'export_format': 'pdf'})
        self.assertEqual(response_pdf.status_code, status.HTTP_200_OK)
        self.assertTrue(response_pdf.has_header('Content-Disposition'))

    def test_process_single_received_sms_shared_number_disambiguation(self):
        from api.views import process_single_received_sms
        
        # Create Airtel, BSNL, Vi sharing the same mobile number '7353224350'
        airtel = TSPProvider.objects.create(name="Bharti Airtel", code="AIRTEL", contact_email="airtel@test.com", mobile_number="7353224350")
        bsnl = TSPProvider.objects.create(name="BSNL", code="BSNL", contact_email="bsnl@test.com", mobile_number="7353224350")
        vi = TSPProvider.objects.create(name="Vodafone Idea (Vi)", code="VI", contact_email="vi@test.com", mobile_number="7353224350")
        
        # Create forwarded requests for Airtel and BSNL
        req_airtel = Request.objects.create(
            mobile_number="9999911111", tsp=airtel, reason="Test Airtel", officer=self.officer, status=RequestStatus.FORWARDED
        )
        req_bsnl = Request.objects.create(
            mobile_number="9999922222", tsp=bsnl, reason="Test BSNL", officer=self.officer, status=RequestStatus.FORWARDED
        )
        
        # Simulate SMS from shared number '7353224350' mentioning BSNL
        success = process_single_received_sms(
            sms_id="sms_test_bsnl",
            sender="7353224350",
            message="BSNL Status: Active\nCircle: Karnataka\nActivation Date: 2026-06-13",
            received_at_str="2026-06-13T10:00:00Z"
        )
        self.assertTrue(success)
        
        # Verify the BSNL request status changed to TSP_RESPONDED
        req_bsnl.refresh_from_db()
        self.assertEqual(req_bsnl.status, RequestStatus.TSP_RESPONDED)
        
        # Verify Airtel request status is still FORWARDED
        req_airtel.refresh_from_db()
        self.assertEqual(req_airtel.status, RequestStatus.FORWARDED)

    def test_prevent_forwarding_acknowledgments_and_invalid_completes(self):
        # Create a forwarded request and an acknowledgment response for it
        req = Request.objects.create(
            mobile_number="9876543210", tsp=self.jio, reason="Test", officer=self.officer, status=RequestStatus.TSP_RESPONDED
        )
        
        from api.models import TSPResponse
        resp = TSPResponse.objects.create(
            request=req,
            details="Okay we will reply soon",
            subscriber_status="Under Process",
            status="Received",
            mobile_number="9876543210",
            tsp_provider=self.jio.name,
            submitted_by=self.admin,
            created_by=self.admin
        )

        # Login as Admin
        self.client.force_authenticate(user=self.admin)

        # 1. Verification that we CAN send the response to officer
        url_send = reverse('tsp-response-send-to-officer', args=[resp.id])
        response_send = self.client.post(url_send, {}, format='json')
        self.assertEqual(response_send.status_code, status.HTTP_200_OK)
        req.refresh_from_db()
        self.assertEqual(req.status, RequestStatus.COMPLETED)

        # 2. Try to complete a pending request (without valid response)
        req_invalid = Request.objects.create(
            mobile_number="9876543211", tsp=self.jio, reason="Test", officer=self.officer, status=RequestStatus.PENDING
        )
        url_complete = reverse('request-admin-complete', args=[req_invalid.id])
        response_complete = self.client.post(url_complete, {'remarks': 'Complete this'}, format='json')
        self.assertEqual(response_complete.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("Cannot complete request without a valid TSP response", response_complete.data["detail"])

    def test_process_single_received_sms_unmatched(self):
        from api.views import process_single_received_sms
        from api.models import TSPResponse
        
        # Count existing unmatched/total TSP responses
        initial_count = TSPResponse.objects.filter(request__isnull=True).count()
        
        # Simulate SMS that doesn't match any request in the database
        success = process_single_received_sms(
            sms_id="sms_unmatched_test_123",
            sender="+918310695096", 
            message="Jio Status: Active\nCircle: Karnataka\nActivation Date: 2026-06-13\nNumber: 9988776655",
            received_at_str="2026-06-18T10:00:00Z"
        )
        self.assertFalse(success)
        
        # Verify that NO orphan TSPResponse was created
        final_count = TSPResponse.objects.filter(request__isnull=True).count()
        self.assertEqual(final_count, initial_count)

    def test_process_single_received_sms_admin_absent_approved(self):
        from api.views import process_single_received_sms
        from api.models import TSPResponse, RequestStatusLog
        
        # Create a forwarded request with is_absent_approved = True
        bsnl = TSPProvider.objects.create(name="BSNL", code="BSNL", contact_email="bsnl@test.com", mobile_number="7353224350")
        req_bsnl = Request.objects.create(
            mobile_number="9999922222",
            tsp=bsnl,
            reason="Test BSNL Absent Mode",
            officer=self.officer,
            status=RequestStatus.FORWARDED,
            is_absent_approved=True
        )
        
        # Simulate SMS from shared number '7353224350' mentioning BSNL
        success = process_single_received_sms(
            sms_id="sms_test_bsnl_absent",
            sender="7353224350",
            message="BSNL Status: Active\nCircle: Karnataka\nActivation Date: 2026-06-13",
            received_at_str="2026-06-13T10:00:00Z"
        )
        self.assertTrue(success)
        
        # Verify the BSNL request status changed directly to COMPLETED and admin_status to Completed
        req_bsnl.refresh_from_db()
        self.assertEqual(req_bsnl.status, RequestStatus.COMPLETED)
        self.assertEqual(req_bsnl.admin_status, 'Completed')
        self.assertIn("Active", req_bsnl.response)
        
        # Verify TSPResponse is created with status 'Sent to Officer'
        tsp_resp = TSPResponse.objects.filter(request=req_bsnl).first()
        self.assertIsNotNone(tsp_resp)
        assert tsp_resp is not None
        self.assertEqual(tsp_resp.status, 'Sent to Officer')
        self.assertEqual(tsp_resp.subscriber_status, 'Active')
        
        # Verify status log exists for the COMPLETED state
        log_exists = RequestStatusLog.objects.filter(request=req_bsnl, status=RequestStatus.COMPLETED).exists()
        self.assertTrue(log_exists)

    def test_build_tsp_forward_sms_custom_template(self):
        from api.views import build_tsp_forward_sms
        from api.models import TspSetting
        
        # Jio TSP Provider is self.jio
        # Create a TspSetting with a custom multiline template
        TspSetting.objects.create(
            tsp_name="Jio",
            forward_number="9876543211",
            sms_template="Please provide current location for <Number>\nDistrict: Bengaluru\nRequested by: Officer Test"
        )
        
        # Create a pending request
        req = Request.objects.create(
            mobile_number="6383836472", tsp=self.jio, reason="Looking for tracing", officer=self.officer, status=RequestStatus.PENDING
        )
        
        # Build SMS message
        sms_msg, target_phone = build_tsp_forward_sms(req)
        
        # Verify target phone number is retrieved from setting
        self.assertEqual(target_phone, "9876543211")
        
        # Verify template variables are replaced and multiline formatting is preserved
        expected_msg = "Please provide current location for 6383836472\nDistrict: Bengaluru\nRequested by: Officer Test"
        self.assertEqual(sms_msg, expected_msg)
        
        # Verify that it is case-insensitive to placeholder '<number>'
        setting_lower = TspSetting.objects.get(tsp_name="Jio")
        setting_lower.sms_template = "Trace <number> immediately."
        setting_lower.save()
        
        sms_msg_lower, _ = build_tsp_forward_sms(req)
        self.assertEqual(sms_msg_lower, "Trace 6383836472 immediately.")

    def test_get_and_update_profile(self):
        # 1. Test GET request
        self.client.force_authenticate(user=self.admin)
        url = reverse('profile')
        response = self.client.get(url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['username'], self.admin.username)
        # Check phone number is returned for admin (defaults to 9844281875 if setting missing)
        self.assertEqual(response.data['phone_number'], '9844281875')

        # 2. Test PUT request to update profile details
        data = {
            'username': 'admin_updated',
            'phone_number': '1234567890',
            'password': 'newpassword123'
        }
        response = self.client.put(url, data, format='json')
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data['username'], 'admin_updated')
        self.assertEqual(response.data['phone_number'], '1234567890')

        # Verify database got updated
        self.admin.refresh_from_db()
        self.assertEqual(self.admin.username, 'admin_updated')
        self.admin.check_password('newpassword123')

    def test_process_single_received_sms_deduplication(self):
        from api.views import process_single_received_sms
        from api.models import TSPResponse

        # Create a forwarded request
        req = Request.objects.create(
            mobile_number="9876500001", tsp=self.jio, reason="Test duplicate check", officer=self.officer, status=RequestStatus.FORWARDED
        )

        # 1. Process the SMS response for the first time
        success1 = process_single_received_sms(
            sms_id="sms_dup_test_1",
            sender=self.jio.mobile_number,
            message="Done",
            received_at_str="2026-06-24T12:00:00Z"
        )
        self.assertTrue(success1)

        # Verify exactly one TSPResponse is created
        responses = TSPResponse.objects.filter(request=req)
        self.assertEqual(responses.count(), 1)
        self.assertEqual(responses.first().details, "Done")

        # 2. Process the exact same SMS message again (simulate duplicate webhook/poller run)
        success2 = process_single_received_sms(
            sms_id="sms_dup_test_2",
            sender=self.jio.mobile_number,
            message="Done",
            received_at_str="2026-06-24T12:01:00Z"
        )
        # Should return False (ignored)
        self.assertFalse(success2)

        # Verify that still exactly one TSPResponse exists
        self.assertEqual(TSPResponse.objects.filter(request=req).count(), 1)

    def test_process_single_received_sms_direct_forwarded(self):
        from api.views import process_single_received_sms
        from api.models import TSPResponse, RequestStatusLog
        
        # Create a forwarded request with is_direct_forwarded = True
        bsnl = TSPProvider.objects.create(name="BSNL", code="BSNL", contact_email="bsnl@test.com", mobile_number="7353224351")
        req_bsnl = Request.objects.create(
            mobile_number="9999933333",
            tsp=bsnl,
            reason="Test BSNL Direct Forward Mode",
            officer=self.officer,
            status=RequestStatus.FORWARDED,
            is_direct_forwarded=True
        )
        
        # Simulate SMS from number '7353224351' mentioning BSNL
        success = process_single_received_sms(
            sms_id="sms_test_bsnl_direct",
            sender="7353224351",
            message="BSNL Status: Active\nCircle: Karnataka\nActivation Date: 2026-06-13",
            received_at_str="2026-06-13T10:00:00Z"
        )
        self.assertTrue(success)
        
        # Verify the BSNL request status changed directly to COMPLETED and admin_status to Completed
        req_bsnl.refresh_from_db()
        self.assertEqual(req_bsnl.status, RequestStatus.COMPLETED)
        self.assertEqual(req_bsnl.admin_status, 'Completed')
        self.assertIn("Active", req_bsnl.response)
        
        # Verify TSPResponse is created with status 'Sent to Officer'
        tsp_resp = TSPResponse.objects.filter(request=req_bsnl).first()
        self.assertIsNotNone(tsp_resp)
        assert tsp_resp is not None
        self.assertEqual(tsp_resp.status, 'Sent to Officer')
        self.assertEqual(tsp_resp.subscriber_status, 'Active')
        
        # Verify status log exists for the COMPLETED state
        log_exists = RequestStatusLog.objects.filter(request=req_bsnl, status=RequestStatus.COMPLETED).exists()
        self.assertTrue(log_exists)

    def test_process_single_received_sms_global_direct_forwarded(self):
        from api.views import process_single_received_sms
        from api.models import TSPResponse, RequestStatusLog
        
        # Create a forwarded request with is_auto_approved = True (global direct send option)
        bsnl = TSPProvider.objects.create(name="BSNL", code="BSNL", contact_email="bsnl@test.com", mobile_number="7353224352")
        req_bsnl = Request.objects.create(
            mobile_number="9999944444",
            tsp=bsnl,
            reason="Test BSNL Global Direct Forward Mode",
            officer=self.officer,
            status=RequestStatus.FORWARDED,
            is_auto_approved=True
        )
        
        # Simulate SMS from number '7353224352' mentioning BSNL
        success = process_single_received_sms(
            sms_id="sms_test_bsnl_global_direct",
            sender="7353224352",
            message="BSNL Status: Active\nCircle: Karnataka\nActivation Date: 2026-06-13",
            received_at_str="2026-06-13T10:00:00Z"
        )
        self.assertTrue(success)
        
        # Verify the BSNL request status changed directly to COMPLETED
        req_bsnl.refresh_from_db()
        self.assertEqual(req_bsnl.status, RequestStatus.COMPLETED)
        self.assertEqual(req_bsnl.admin_status, 'Completed')
        
        # Verify TSPResponse is created with status 'Sent to Officer'
        tsp_resp = TSPResponse.objects.filter(request=req_bsnl).first()
        self.assertIsNotNone(tsp_resp)
        self.assertEqual(tsp_resp.status, 'Sent to Officer')







