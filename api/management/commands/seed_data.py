# type: ignore
# mypy: ignore-errors
from django.core.management.base import BaseCommand
from api.models import User, TSPProvider, PermissionSetting, SystemSetting, UserRole

class Command(BaseCommand):
    help = 'Seeds initial data for SMS Forwarding & TSP Information Management System'

    def handle(self, *args, **kwargs):
        self.stdout.write('Seeding initial data...')

        # 1. Create TSPs
        tsps_data = [
            {'name': 'Reliance Jio', 'code': 'JIO', 'email': 'support@jio.com', 'inbound_number': '9844281875', 'mobile_number': '8310695096', 'sms_template': 'Location <Number>'},
            {'name': 'Bharti Airtel', 'code': 'AIRTEL', 'email': 'support@airtel.com', 'inbound_number': '9844281875', 'mobile_number': '7353224350', 'sms_template': 'Loc <Number>'},
            {'name': 'BSNL', 'code': 'BSNL', 'email': 'support@bsnl.co.in', 'inbound_number': '9844281875', 'mobile_number': '7353224350', 'sms_template': 'LOCATE <Number>'},
            {'name': 'Vodafone Idea (Vi)', 'code': 'VI', 'email': 'support@vi.com', 'inbound_number': '9844281875', 'mobile_number': '7353224350', 'sms_template': 'Need Loc <Number>'},
        ]

        tsps = {}
        for data in tsps_data:
            tsp, created = TSPProvider.objects.get_or_create(
                code=data['code'],
                defaults={
                    'name': data['name'],
                    'contact_email': data['email'],
                    'inbound_number': data['inbound_number'],
                    'mobile_number': data.get('mobile_number', ''),
                    'sms_template': data.get('sms_template', ''),
                    'is_active': True
                }
            )
            if not created:
                tsp.sms_template = data.get('sms_template', '')
                tsp.save()
            tsps[data['code']] = tsp
            if created:
                self.stdout.write(f"Created TSP: {data['name']}")
            else:
                self.stdout.write(f"TSP {data['name']} already exists (updated template)")

        # 2. Create Admin
        admin_user, created = User.objects.get_or_create(
            username='admin',
            defaults={
                'email': 'admin@smstsp.com',
                'role': UserRole.ADMIN,
                'is_staff': True,
                'is_superuser': True
            }
        )
        if created:
            admin_user.set_password('Admin@1234')
            admin_user.save()
            self.stdout.write("Created Admin User: 'admin' (password: 'Admin@1234')")
        else:
            self.stdout.write("Admin User already exists")

        # 3. Create Field Officers
        officers_data = [
            {'username': 'officer_ranjeet', 'email': 'officer@smstsp.com', 'password': 'Officer@1234', 'direct_forward': True},
            {'username': 'officer_neha', 'email': 'neha@police.gov.in', 'password': 'officerpassword123', 'direct_forward': False},
        ]

        for data in officers_data:
            officer, created = User.objects.get_or_create(
                username=data['username'],
                defaults={
                    'email': data['email'],
                    'role': UserRole.OFFICER
                }
            )
            if created:
                officer.set_password(data['password'])
                officer.save()
                self.stdout.write(f"Created Field Officer: '{data['username']}' (password: 'officerpassword123')")
            else:
                self.stdout.write(f"Field Officer '{data['username']}' already exists")
            
            # Create permission setting
            perm, perm_created = PermissionSetting.objects.get_or_create(
                officer=officer,
                defaults={'direct_forward_allowed': data['direct_forward']}
            )
            if perm_created:
                self.stdout.write(f"Created Permission Setting for {officer.username} - Direct Forward: {data['direct_forward']}")

        # 4. Create TSP Representatives
        reps_data = [
            {'username': 'rep_jio', 'email': 'rep@jio.com', 'tsp': 'JIO'},
            {'username': 'rep_airtel', 'email': 'rep@airtel.com', 'tsp': 'AIRTEL'},
            {'username': 'rep_bsnl', 'email': 'rep@bsnl.co.in', 'tsp': 'BSNL'},
            {'username': 'rep_vi', 'email': 'rep@vi.com', 'tsp': 'VI'},
        ]

        for data in reps_data:
            rep, created = User.objects.get_or_create(
                username=data['username'],
                defaults={
                    'email': data['email'],
                    'role': UserRole.TSP,
                    'tsp_provider': tsps[data['tsp']]
                }
            )
            if not created:
                rep.tsp_provider = tsps[data['tsp']]
                rep.role = UserRole.TSP
                rep.save()
                self.stdout.write(f"Updated TSP Representative: '{data['username']}' for {data['tsp']}")
            else:
                rep.set_password('tsppassword123')
                rep.save()
                self.stdout.write(f"Created TSP Representative: '{data['username']}' for {data['tsp']} (password: 'tsppassword123')")

        # 5. Create Default Settings
        setting, created = SystemSetting.objects.get_or_create(
            key='auto_approval_mode',
            defaults={'value': 'false'}
        )
        if created:
            self.stdout.write("Created Default Setting: auto_approval_mode = false")
        else:
            self.stdout.write("System Setting auto_approval_mode already exists")

        setting_routing, created_routing = SystemSetting.objects.get_or_create(
            key='auto_routing_mode',
            defaults={'value': 'true'}
        )
        if created_routing:
            self.stdout.write("Created Default Setting: auto_routing_mode = true")
        else:
            self.stdout.write("System Setting auto_routing_mode already exists")

        self.stdout.write(self.style.SUCCESS('Data seeding completed successfully!'))
