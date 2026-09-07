@IsTest
private class CollaborationCredentialServiceTest {
    @IsTest static void constructsTenantEndpoints() {
        String tenant = '12345678-1234-4234-9234-1234567890ab';
        System.assertEquals('https://login.microsoftonline.com/' + tenant + '/oauth2/v2.0/authorize', CollaborationCredentialService.microsoftAuthorizeUrl(tenant));
        System.assertEquals('https://login.microsoftonline.com/' + tenant + '/oauth2/v2.0/token', CollaborationCredentialService.microsoftTokenUrl(tenant));
    }
    @IsTest static void rejectsUnsafeTenant() {
        Boolean thrown = false;
        try { CollaborationCredentialService.microsoftAuthorizeUrl('evil.example.com'); } catch (AuraHandledException e) { thrown = true; }
        System.assert(thrown, 'Arbitrary tenant endpoints must be rejected.');
    }
}