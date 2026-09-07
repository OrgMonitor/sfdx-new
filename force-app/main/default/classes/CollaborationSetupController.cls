public with sharing class CollaborationSetupController {
    public class ProviderState {
        @AuraEnabled public CollaborationCredentialService.OAuthInfo oauthInfo;
        @AuraEnabled public String identityId; @AuraEnabled public String identityName;
        @AuraEnabled public String tenantId;
        @AuraEnabled public String teamId; @AuraEnabled public String teamName;
        @AuraEnabled public String channelId; @AuraEnabled public String channelName;
        @AuraEnabled public Datetime lastTest; @AuraEnabled public Boolean privateChannels;
        @AuraEnabled public Boolean setupComplete;
    }
    @AuraEnabled public static ProviderState getProviderState(String provider) {
        validate(provider); ProviderState result = new ProviderState(); result.oauthInfo = CollaborationCredentialService.getOAuthInfo(provider);
        ChangeLogRuntime__c s = ChangeLogRuntime__c.getOrgDefaults(); if (s == null) return result;
        if (provider == 'slack') { result.identityId=s.Slack_Workspace_Id__c; result.identityName=s.Slack_Workspace_Name__c; result.channelId=s.Slack_Channel_Id__c; result.channelName=s.Slack_Channel_Name__c; result.lastTest=s.Slack_Last_Test__c; result.privateChannels=s.Slack_Private_Channels__c; result.setupComplete = String.isNotBlank(s.Slack_Workspace_Id__c) && String.isNotBlank(s.Slack_Channel_Id__c); }
        else { result.tenantId=s.Teams_Tenant_Id__c; result.identityId=s.Teams_Identity_Id__c; result.identityName=s.Teams_Identity_Name__c; result.teamId=s.Teams_Team_Id__c; result.teamName=s.Teams_Team_Name__c; result.channelId=s.Teams_Channel_Id__c; result.channelName=s.Teams_Channel_Name__c; result.lastTest=s.Teams_Last_Test__c; result.setupComplete = String.isNotBlank(s.Teams_Identity_Id__c) && String.isNotBlank(s.Teams_Team_Id__c) && String.isNotBlank(s.Teams_Channel_Id__c); }
        return result;
    }
    @AuraEnabled public static void saveProviderState(String provider, String identityId, String identityName, String teamId, String teamName, String channelId, String channelName, Boolean tested) {
        validateEnabled(provider); validateSafe(identityId); validateSafe(identityName); validateSafe(teamId); validateSafe(teamName); validateSafe(channelId); validateSafe(channelName);
        ChangeLogRuntime__c s = ChangeLogRuntime__c.getOrgDefaults(); if (s == null) s = new ChangeLogRuntime__c();
        if (provider == 'slack') { Boolean changed = (identityId != null && identityId != s.Slack_Workspace_Id__c) || (channelId != null && channelId != s.Slack_Channel_Id__c); if (identityId != null) s.Slack_Workspace_Id__c=identityId; if (identityName != null) s.Slack_Workspace_Name__c=identityName; if (channelId != null) s.Slack_Channel_Id__c=channelId; if (channelName != null) s.Slack_Channel_Name__c=channelName; if (changed || tested != true) s.Slack_Last_Test__c=null; }
        else { Boolean identityChanged = s.Teams_Identity_Id__c != null && identityId != null && identityId != s.Teams_Identity_Id__c; Boolean changed = identityChanged || (teamId != null && teamId != s.Teams_Team_Id__c) || (channelId != null && channelId != s.Teams_Channel_Id__c); if (identityId != null) s.Teams_Identity_Id__c=identityId; if (identityName != null) s.Teams_Identity_Name__c=identityName; if (teamId != null) s.Teams_Team_Id__c=teamId; if (teamName != null) s.Teams_Team_Name__c=teamName; if (channelId != null) s.Teams_Channel_Id__c=channelId; if (channelName != null) s.Teams_Channel_Name__c=channelName; if (changed || tested != true) s.Teams_Last_Test__c=null; }
        upsert s;
    }
    @AuraEnabled public static CollaborationCredentialService.OAuthInfo getOAuthInfo(String provider) { validate(provider); return CollaborationCredentialService.getOAuthInfo(provider); }
    @AuraEnabled public static String getAuthenticationUrl(String provider) { validateEnabled(provider); requireConfiguration(provider); return CollaborationCredentialService.getOAuthInfo(provider).authenticationUrl; }
    @AuraEnabled public static CollaborationCredentialService.OAuthInfo provisionProvider(String provider, String tenantId, Boolean privateChannels) { validate(provider); return CollaborationCredentialService.provision(provider, tenantId, privateChannels); }
    @AuraEnabled public static void populateProviderCredentials(String provider, String clientId, String clientSecret) { validateEnabled(provider); if (!validClientId(provider, clientId)) fail('INVALID_CLIENT_ID'); if (String.isBlank(clientSecret)) fail('CONFIGURATION_REQUIRED'); CollaborationCredentialService.populateCredentials(provider, clientId, clientSecret); }
    @AuraEnabled public static CollaborationCredentialService.OAuthInfo saveProviderConfiguration(String provider, String tenantId, Boolean privateChannels, String clientId, String clientSecret) {
        validateEnabled(provider);
        if (provider == 'microsoft' && String.isBlank(tenantId)) fail('MICROSOFT_TENANT_ID_REQUIRED');
        if (provider == 'microsoft' && !validTenantId(tenantId)) fail('INVALID_TENANT_ID');
        if (String.isBlank(clientId)) fail(provider == 'slack' ? 'SLACK_CLIENT_ID_REQUIRED' : 'MICROSOFT_CLIENT_ID_REQUIRED');
        if (!validClientId(provider, clientId)) fail(provider == 'slack' ? 'SLACK_CLIENT_ID_INVALID' : 'MICROSOFT_CLIENT_ID_INVALID');
        if (String.isBlank(clientSecret)) fail(provider == 'slack' ? 'SLACK_CLIENT_SECRET_REQUIRED' : 'MICROSOFT_CLIENT_SECRET_REQUIRED');
        try { CollaborationCredentialService.provision(provider, tenantId, privateChannels); }
        catch (AuraHandledException e) { throw e; }
        catch (Exception e) { fail(provider == 'slack' ? 'SLACK_CREDENTIAL_CONFIGURATION_FAILED' : 'MICROSOFT_CREDENTIAL_CONFIGURATION_FAILED'); }
        try { CollaborationCredentialService.populateCredentials(provider, clientId.trim(), clientSecret); }
        catch (Exception e) { fail(provider == 'slack' ? 'SLACK_CREDENTIAL_API_UNAVAILABLE' : 'MICROSOFT_CREDENTIAL_API_UNAVAILABLE'); }
        try {
            CollaborationCredentialService.OAuthInfo result = CollaborationCredentialService.getOAuthInfo(provider);
            if (result.credentialsConfigured != true || result.configured != true) fail(provider == 'slack' ? 'SLACK_CREDENTIAL_CONFIGURATION_FAILED' : 'MICROSOFT_CREDENTIAL_CONFIGURATION_FAILED');
            if (provider == 'slack') persistSlackPrivateChannels(privateChannels == true);
            else persistMicrosoftTenant(tenantId);
            return result;
        } catch (AuraHandledException e) { throw e; }
        catch (Exception e) { fail(provider == 'slack' ? 'SLACK_CREDENTIAL_CONFIGURATION_FAILED' : 'MICROSOFT_CREDENTIAL_CONFIGURATION_FAILED'); }
        return null;
    }
    @AuraEnabled public static CollaborationNotificationService.Identity verifyConnection(String provider) { validateEnabled(provider); try { return provider == 'slack' ? CollaborationNotificationService.verifySlack() : CollaborationNotificationService.verifyMicrosoft(); } catch (AuraHandledException e) { throw e; } catch (Exception e) { if (isCalloutsDisabled(e)) fail('CALLOUTS_DISABLED'); fail('AUTHORIZATION_REQUIRED'); } return null; }
    @AuraEnabled public static List<CollaborationNotificationService.Destination> getDestinations(String provider, String teamId) { validateEnabled(provider); try { if (provider == 'slack') { ChangeLogRuntime__c setting = ChangeLogRuntime__c.getOrgDefaults(); return CollaborationNotificationService.getSlackChannels(setting != null && setting.Slack_Private_Channels__c); } return String.isBlank(teamId) ? CollaborationNotificationService.getMicrosoftTeams() : CollaborationNotificationService.getMicrosoftChannels(teamId); } catch (AuraHandledException e) { throw e; } catch (Exception e) { fail('CONNECTION_NOT_VERIFIED'); } return null; }
    @AuraEnabled public static void sendTestMessage(String provider, String teamId, String channelId) { validateEnabled(provider); if (String.isBlank(channelId)) fail('CHANNEL_REQUIRED'); try { if (provider == 'slack') CollaborationNotificationService.sendSlackTest(channelId); else { if (String.isBlank(teamId)) fail('TEAM_REQUIRED'); CollaborationNotificationService.sendMicrosoftTest(teamId, channelId); } markSuccessfulTest(provider, teamId, channelId); } catch (AuraHandledException e) { throw e; } catch (Exception e) { fail('CONNECTION_NOT_VERIFIED'); } }
    @AuraEnabled public static void disconnect(String provider) { validate(provider); CollaborationCredentialService.disconnect(provider); clearProviderStateAsync(provider); }
    private static void validate(String provider) { OrgMonitorSetupSecurity.requireManageSetup(); if (provider != 'slack' && provider != 'microsoft') throw new AuraHandledException('Unsupported collaboration provider.'); }
    private static void validateEnabled(String provider) { validate(provider); ChangeLogRuntime__c s = ChangeLogRuntime__c.getOrgDefaults(); Boolean enabled = s != null && (provider == 'slack' ? s.Slack_Notifications_Enabled__c : s.Teams_Notifications_Enabled__c); if (!enabled) fail('PROVIDER_DISABLED'); }
    private static void requireConfiguration(String provider) { CollaborationCredentialService.OAuthInfo info = CollaborationCredentialService.getOAuthInfo(provider); if (info.credentialsConfigured != true) fail('CONFIGURATION_REQUIRED'); }
    private static void fail(String code) { throw new AuraHandledException(code); }
    private static Boolean isCalloutsDisabled(Exception e) { return e != null && e.getMessage() != null && e.getMessage().contains('Enabled for Callouts'); }
    private static void validateSafe(String value) { if (value != null && (value.length() > 255 || value.contains('\n') || value.contains('\r'))) fail('INVALID_STATE'); }
    @future private static void persistSlackPrivateChannels(Boolean enabled) { ChangeLogRuntime__c setting = ChangeLogRuntime__c.getOrgDefaults(); if (setting == null) setting = new ChangeLogRuntime__c(); setting.Slack_Private_Channels__c = enabled == true; setting.Slack_Workspace_Id__c=null; setting.Slack_Workspace_Name__c=null; setting.Slack_Channel_Id__c=null; setting.Slack_Channel_Name__c=null; setting.Slack_Last_Test__c=null; upsert setting; }
    @future private static void persistMicrosoftTenant(String tenantId) { ChangeLogRuntime__c setting = ChangeLogRuntime__c.getOrgDefaults(); if (setting == null) setting = new ChangeLogRuntime__c(); setting.Teams_Tenant_Id__c = tenantId == null ? null : tenantId.trim(); setting.Teams_Identity_Id__c=null; setting.Teams_Identity_Name__c=null; setting.Teams_Team_Id__c=null; setting.Teams_Team_Name__c=null; setting.Teams_Channel_Id__c=null; setting.Teams_Channel_Name__c=null; setting.Teams_Last_Test__c=null; upsert setting; }
    private static void markSuccessfulTest(String provider, String teamId, String channelId) {
        ChangeLogRuntime__c setting = ChangeLogRuntime__c.getOrgDefaults();
        if (setting == null) fail('DESTINATION_NOT_SAVED');
        if (provider == 'slack' && setting.Slack_Channel_Id__c != channelId) fail('DESTINATION_CHANGED');
        if (provider == 'microsoft' && (setting.Teams_Team_Id__c != teamId || setting.Teams_Channel_Id__c != channelId)) fail('DESTINATION_CHANGED');
        if (provider == 'slack') setting.Slack_Last_Test__c=System.now(); else setting.Teams_Last_Test__c=System.now();
        upsert setting;
    }
    @future private static void clearProviderStateAsync(String provider) {
        ChangeLogRuntime__c setting = ChangeLogRuntime__c.getOrgDefaults(); if (setting == null) return;
        if (provider == 'slack') { setting.Slack_Workspace_Id__c=null; setting.Slack_Workspace_Name__c=null; setting.Slack_Channel_Id__c=null; setting.Slack_Channel_Name__c=null; setting.Slack_Last_Test__c=null; }
        else { setting.Teams_Identity_Id__c=null; setting.Teams_Identity_Name__c=null; setting.Teams_Tenant_Id__c=null; setting.Teams_Team_Id__c=null; setting.Teams_Team_Name__c=null; setting.Teams_Channel_Id__c=null; setting.Teams_Channel_Name__c=null; setting.Teams_Last_Test__c=null; }
        upsert setting;
    }
    @TestVisible private static Boolean validClientId(String provider, String value) { if (String.isBlank(value)) return false; return provider == 'slack' ? Pattern.matches('^\\d+\\.\\d+$', value.trim()) : Pattern.matches('(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', value.trim()); }
    @TestVisible private static Boolean validTenantId(String value) { return !String.isBlank(value) && Pattern.matches('(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', value.trim()); }
}