import os
import django

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'backend.settings')
django.setup()

from api.models import TSPProvider, TspSetting
from api.serializers import TSPProviderSerializer

try:
    jio = TSPProvider.objects.filter(code='JIO').first()
    if not jio:
        print("Jio provider not found!")
    else:
        print(f"Current Jio: mobile_number={jio.mobile_number}, sms_template={jio.sms_template}")
        
        # Check TspSetting
        setting = TspSetting.objects.filter(tsp_name='Jio').first()
        if setting:
            print(f"Existing TspSetting Jio: id={setting.id}, name={setting.tsp_name}, forward={setting.forward_number}")
        else:
            print("No TspSetting for Jio exists!")
            
        print("All TspSettings in DB:")
        for s in TspSetting.objects.all():
            print(f" - id={s.id}, name={s.tsp_name}, forward={s.forward_number}")

        # Try save setting manually
        if setting:
            setting.forward_number = '8310695096'
            setting.sms_template = 'loc<number>'
            print("Saving manually...")
            setting.save()
            print("Successfully saved manually!")

except Exception as e:
    import traceback
    print("An exception occurred during update:")
    traceback.print_exc()
