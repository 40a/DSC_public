﻿Enter-PSSession dc1
Set-CertificateAutoEnrollmentPolicy -PolicyState Enabled -EnableMyStoreManagement -EnableTemplateCheck -context Machine