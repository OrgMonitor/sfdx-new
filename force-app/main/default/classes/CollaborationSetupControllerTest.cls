@IsTest
private class CollaborationSetupControllerTest {
    private class SlackMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse(); response.setStatusCode(200);
            if (request.getEndpoint().contains('auth.test')) response.setBody('{"ok":true,"team_id":"T1","team":"Org Monitor","user":"admin"}');
            else response.setBody('{"ok":true,"channels":[],"response_metadata":{"next_cursor":""}}');
            return response;
        }
    }
    @IsTest static void disabledProviderCannotCallServices() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        insert new ChangeLogRuntime__c(SetupOwnerId = UserInfo.getOrganizationId(), Slack_Notifications_Enabled__c = false, Teams_Notifications_Enabled__c = false);
        assertRejected('slack'); assertRejected('microsoft');
    }
    @IsTest static void validatesSlackClientIdsIndependently() {
        System.assert(CollaborationSetupController.validClientId('slack', ' 11880922238419.11896545574118 '));
        System.assert(!CollaborationSetupController.validClientId('slack', '11880922238419'));
        System.assert(!CollaborationSetupController.validClientId('slack', 'https://slack.com'));
        System.assert(!CollaborationSetupController.validClientId('slack', '11880922238419. 11896545574118'));
        System.assert(!CollaborationSetupController.validClientId('slack', '123e4567-e89b-42d3-a456-426614174000'));
        System.assert(CollaborationSetupController.validClientId('microsoft', '123e4567-e89b-42d3-a456-426614174000'));
    }
    @IsTest static void verifiesSlackInCleanCalloutTransaction() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        insert new ChangeLogRuntime__c(SetupOwnerId = UserInfo.getOrganizationId(), Slack_Notifications_Enabled__c = true);
        Test.setMock(HttpCalloutMock.class, new SlackMock());
        Test.startTest();
        CollaborationNotificationService.Identity identity = CollaborationSetupController.verifyConnection('slack');
        List<CollaborationNotificationService.Destination> channels = CollaborationSetupController.getDestinations('slack', null);
        Test.stopTest();
        System.assertEquals('T1', identity.id);
        System.assertEquals(0, channels.size());
    }
    @IsTest static void successfulTestIsServerStampedAndDestinationChangeInvalidatesIt() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        insert new ChangeLogRuntime__c(SetupOwnerId = UserInfo.getOrganizationId(), Slack_Notifications_Enabled__c = true, Slack_Channel_Id__c = 'C1', Slack_Channel_Name__c = 'alerts');
        Test.setMock(HttpCalloutMock.class, new SlackMock());
        Test.startTest();
        CollaborationSetupController.sendTestMessage('slack', null, 'C1');
        Test.stopTest();
        System.assertNotEquals(null, ChangeLogRuntime__c.getOrgDefaults().Slack_Last_Test__c);
        CollaborationSetupController.saveProviderState('slack', 'T1', 'Workspace', null, null, 'C2', 'security', false);
        System.assertEquals(null, ChangeLogRuntime__c.getOrgDefaults().Slack_Last_Test__c);
        ChangeLogRuntime__c forged = ChangeLogRuntime__c.getOrgDefaults(); forged.Slack_Last_Test__c = System.now(); update forged;
        CollaborationSetupController.saveProviderState('slack', 'T1', 'Workspace', null, null, 'C3', 'other', true);
        System.assertEquals(null, ChangeLogRuntime__c.getOrgDefaults().Slack_Last_Test__c, 'A client cannot carry a successful test to a different destination.');
    }
    @IsTest static void teamsRefreshPreservesTenantAndSuccessfulTest() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        Datetime testedAt = System.now().addMinutes(-5);
        insert new ChangeLogRuntime__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Teams_Notifications_Enabled__c = true,
            Teams_Tenant_Id__c = '123e4567-e89b-42d3-a456-426614174000',
            Teams_Team_Id__c = 'TEAM1',
            Teams_Channel_Id__c = 'CHANNEL1',
            Teams_Last_Test__c = testedAt
        );

        // First load after upgrade migrates the connected identity into its own
        // field without treating it as a destination change.
        CollaborationSetupController.saveProviderState(
            'microsoft', 'USER1', 'Integration User', 'TEAM1', 'Operations',
            'CHANNEL1', 'General', true
        );
        ChangeLogRuntime__c saved = ChangeLogRuntime__c.getOrgDefaults();
        System.assertEquals('123e4567-e89b-42d3-a456-426614174000', saved.Teams_Tenant_Id__c);
        System.assertEquals('USER1', saved.Teams_Identity_Id__c);
        System.assertEquals('Integration User', saved.Teams_Identity_Name__c);
        System.assertNotEquals(null, saved.Teams_Last_Test__c);

        CollaborationSetupController.ProviderState state =
            CollaborationSetupController.getProviderState('microsoft');
        System.assertEquals(saved.Teams_Tenant_Id__c, state.tenantId);
        System.assertEquals('USER1', state.identityId);
        System.assertEquals('Integration User', state.identityName);
    }
    @IsTest static void rejectsUnauthorizedCollaborationAccess() {
        OrgMonitorSetupSecurity.testPermissionGranted = false;
        Boolean thrown = false;
        try { CollaborationSetupController.getProviderState('slack'); } catch (AuraHandledException e) { thrown = true; }
        System.assert(thrown, 'Collaboration setup must require the packaged custom permission.');
    }
    private static void assertRejected(String provider) {
        Boolean thrown = false;
        try { CollaborationSetupController.verifyConnection(provider); } catch (AuraHandledException e) { thrown = true; }
        System.assert(thrown, provider + ' must reject direct calls while disabled.');
    }
}