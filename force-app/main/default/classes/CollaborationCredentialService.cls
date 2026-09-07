public with sharing class CollaborationCredentialService {
    private static final String ADMIN_PERMISSION_SET = 'Org_Monitor_Collaboration_Admin';
    private static final Pattern TENANT_ID = Pattern.compile('(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    public class OAuthInfo { @AuraEnabled public String callbackUrl; @AuraEnabled public String authenticationUrl; @AuraEnabled public String status; @AuraEnabled public Boolean configured; @AuraEnabled public Boolean credentialsConfigured; }

    public static OAuthInfo provision(String provider, String tenantId, Boolean privateChannels) {
        Definition d = definition(provider, tenantId, privateChannels);
        validatePackagedComponents(d);
        return getOAuthInfo(provider);
    }
    public static void populateCredentials(String provider, String clientId, String clientSecret) {
        Definition d = definition(provider, null, false);
        requireValue(clientId, d.label + ' Client ID'); requireValue(clientSecret, d.label + ' Client Secret');
        ConnectApi.ExternalAuthIdentityProviderCredentialsInput input = new ConnectApi.ExternalAuthIdentityProviderCredentialsInput();
        input.credentials = new List<ConnectApi.ExternalAuthIdentityProviderCredentialInput>{ credential('clientId', clientId.trim()), credential('clientSecret', clientSecret) };
        try { ConnectApi.NamedCredentials.updateExternalAuthIdentityProviderCredentials(d.providerName, input); }
        catch (Exception noCredentialsYet) { ConnectApi.NamedCredentials.createExternalAuthIdentityProviderCredentials(d.providerName, input); }
    }
    public static OAuthInfo getOAuthInfo(String provider) {
        Definition d = definition(provider, null, false); OAuthInfo info = new OAuthInfo(); info.status = 'Not Configured'; info.configured = false;
        try {
            info.callbackUrl = ConnectApi.NamedCredentials.getExternalAuthIdentityProvider(d.providerName).callbackUrl;
            ConnectApi.ExternalAuthIdentityProviderCredentials stored = ConnectApi.NamedCredentials.getExternalAuthIdentityProviderCredentials(d.providerName);
            info.credentialsConfigured = stored != null && stored.credentials != null && !stored.credentials.isEmpty();
            ConnectApi.Credential actual = ConnectApi.NamedCredentials.getCredential(d.externalName, d.principalName, ConnectApi.CredentialPrincipalType.NamedPrincipal);
            info.status = String.valueOf(actual.authenticationStatus);
            ConnectApi.OAuthCredentialAuthUrlInput input = new ConnectApi.OAuthCredentialAuthUrlInput();
            input.externalCredential = d.externalName; input.principalName = d.principalName; input.principalType = ConnectApi.CredentialPrincipalType.NamedPrincipal;
            info.authenticationUrl = ConnectApi.NamedCredentials.getOAuthCredentialAuthUrl(input).authenticationUrl;
            validateAuthenticationUrl(info.authenticationUrl);
            info.configured = String.isNotBlank(info.authenticationUrl);
        } catch (Exception notProvisioned) { info.configured = false; }
        return info;
    }
    private static void validateAuthenticationUrl(String value) {
        if (String.isBlank(value) || !value.startsWith('https://')) throw new AuraHandledException('CONFIGURATION_REQUIRED');
        String host = new Url(value).getHost().toLowerCase();
        if (!(host.endsWith('.salesforce.com') || host.endsWith('.force.com') || host == 'slack.com' || host.endsWith('.slack.com') || host == 'login.microsoftonline.com')) throw new AuraHandledException('UNAPPROVED_AUTHENTICATION_URL');
    }
    public static void disconnect(String provider) {
        Definition d = definition(provider, null, false);
        ConnectApi.NamedCredentials.deleteCredential(d.externalName, d.principalName, ConnectApi.CredentialPrincipalType.NamedPrincipal);
    }
    @TestVisible private static String microsoftAuthorizeUrl(String tenantId) { validateTenant(tenantId); return 'https://login.microsoftonline.com/' + tenantId.toLowerCase() + '/oauth2/v2.0/authorize'; }
    @TestVisible private static String microsoftTokenUrl(String tenantId) { validateTenant(tenantId); return 'https://login.microsoftonline.com/' + tenantId.toLowerCase() + '/oauth2/v2.0/token'; }

    private static void validatePackagedComponents(Definition d) {
        try { ConnectApi.NamedCredentials.getExternalAuthIdentityProvider(d.providerName); }
        catch (Exception e) { throw new AuraHandledException('PACKAGE_IDENTITY_PROVIDER_MISSING'); }
        ConnectApi.ExternalCredential externalCredential;
        try { externalCredential = ConnectApi.NamedCredentials.getExternalCredential(d.externalName); }
        catch (Exception e) { throw new AuraHandledException('PACKAGE_EXTERNAL_CREDENTIAL_MISSING'); }
        Boolean principalFound = false;
        if (externalCredential != null && externalCredential.principals != null) for (ConnectApi.ExternalCredentialPrincipal principal : externalCredential.principals) if (principal.principalName == d.principalName) principalFound = true;
        if (!principalFound) throw new AuraHandledException('PACKAGE_NAMED_PRINCIPAL_MISSING');
        try { ConnectApi.NamedCredentials.getNamedCredential(d.namedName); }
        catch (Exception e) { throw new AuraHandledException('PACKAGE_NAMED_CREDENTIAL_MISSING'); }
        List<PermissionSet> sets = [SELECT Id FROM PermissionSet WHERE Name = :ADMIN_PERMISSION_SET LIMIT 1];
        if (sets.isEmpty()) throw new AuraHandledException('PACKAGE_PERMISSION_SET_MISSING');
        if ([SELECT COUNT() FROM PermissionSetAssignment WHERE PermissionSetId = :sets[0].Id AND AssigneeId = :UserInfo.getUserId()] == 0) throw new AuraHandledException('PACKAGE_PERMISSION_ASSIGNMENT_REQUIRED');
    }
    private static Definition definition(String provider, String tenantId, Boolean privateChannels) {
        Definition d = new Definition();
        if (provider == 'slack') {
            d.label='Slack'; d.providerName='OrgMonitor_Slack_IdentityProvider'; d.externalName='OrgMonitor_Slack_OAuth'; d.principalName='OrgMonitor_Slack_Principal'; d.namedName='OrgMonitor_Slack'; d.calloutUrl='https://slack.com';
            d.authorizeUrl='https://slack.com/oauth/v2/authorize'; d.tokenUrl='https://slack.com/api/oauth.v2.access'; d.scope='chat:write channels:read' + (privateChannels == true ? ' groups:read' : '');
        } else if (provider == 'microsoft') {
            String tenant = String.isBlank(tenantId) ? 'organizations' : tenantId.trim();
            d.updateProvider = String.isNotBlank(tenantId);
            d.label='Microsoft Teams'; d.providerName='OrgMonitor_Teams_IdentityProvider'; d.externalName='OrgMonitor_Teams_OAuth'; d.principalName='OrgMonitor_Teams_Principal'; d.namedName='OrgMonitor_MicrosoftGraph'; d.calloutUrl='https://graph.microsoft.com';
            d.authorizeUrl = tenant == 'organizations' ? 'https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize' : microsoftAuthorizeUrl(tenant);
            d.tokenUrl = tenant == 'organizations' ? 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token' : microsoftTokenUrl(tenant);
            d.scope='openid offline_access User.Read Team.ReadBasic.All Channel.ReadBasic.All ChannelMessage.Send';
        } else throw new AuraHandledException('Unsupported collaboration provider.');
        return d;
    }
    private static void validateTenant(String value) { if (String.isBlank(value) || !TENANT_ID.matcher(value.trim()).matches()) throw new AuraHandledException('Tenant ID must be a valid Microsoft Entra directory UUID.'); }
    private static void requireValue(String value, String label) { if (String.isBlank(value) || value.length() > 512) throw new AuraHandledException(label + ' is required.'); }
    private static ConnectApi.ExternalAuthIdentityProviderCredentialInput credential(String name, String value) { ConnectApi.ExternalAuthIdentityProviderCredentialInput item = new ConnectApi.ExternalAuthIdentityProviderCredentialInput(); item.credentialName=name; item.credentialValue=value; return item; }
    private class Definition { String label; String providerName; String externalName; String principalName; String namedName; String calloutUrl; String authorizeUrl; String tokenUrl; String scope; Boolean updateProvider = false; }
}