@IsTest
private class OrgMonitorNotificationServiceTest {
    private class ProviderMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            if (request.getEndpoint().contains('OrgMonitor_Slack')) {
                response.setBody('{"ok":true,"ts":"123.456"}');
            } else {
                response.setBody('{"id":"teams-message-1"}');
            }
            return response;
        }
    }

    @IsTest static void queuesAndDeliversEachConfiguredProvider() {
        insert new ChangeLogRuntime__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Slack_Notifications_Enabled__c = true,
            Slack_Workspace_Id__c = 'T1',
            Slack_Channel_Id__c = 'C1',
            Slack_Channel_Name__c = 'alerts',
            Slack_Last_Test__c = System.now(),
            Teams_Notifications_Enabled__c = true,
            Teams_Team_Id__c = 'TEAM1',
            Teams_Channel_Id__c = 'CHANNEL1',
            Teams_Channel_Name__c = 'General',
            Teams_Last_Test__c = System.now()
        );
        Test.setMock(HttpCalloutMock.class, new ProviderMock());
        OrgMonitorNotificationService.NotificationRequest request = request('delivery-1');

        Test.startTest();
        List<OrgMonitorNotificationService.DispatchResult> results =
            OrgMonitorNotificationService.send(request);
        Test.stopTest();

        System.assertEquals(2, results.size());
        System.assertEquals(2, [SELECT count() FROM Governance_Notification__c WHERE Status__c = 'Sent']);
        for (Governance_Notification__c row : [
            SELECT Provider__c, Provider_Message_Id__c, Message__c FROM Governance_Notification__c
        ]) {
            System.assertEquals('A completed message.', row.Message__c);
            System.assertNotEquals(null, row.Provider_Message_Id__c);
        }
    }

    @IsTest static void skipsIncompleteProvidersWithoutCreatingRecords() {
        insert new ChangeLogRuntime__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Slack_Notifications_Enabled__c = true,
            Teams_Notifications_Enabled__c = false
        );
        List<OrgMonitorNotificationService.DispatchResult> results =
            OrgMonitorNotificationService.send(request('skipped-1'));
        System.assertEquals(2, results.size());
        System.assertEquals('SKIPPED', results[0].state);
        System.assertEquals('SKIPPED', results[1].state);
        System.assertEquals(0, [SELECT count() FROM Governance_Notification__c]);
    }

    @IsTest static void preventsDuplicateProviderDelivery() {
        insert new ChangeLogRuntime__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Slack_Notifications_Enabled__c = true,
            Slack_Channel_Id__c = 'C1',
            Slack_Last_Test__c = System.now(),
            Teams_Notifications_Enabled__c = false
        );
        OrgMonitorNotificationService.NotificationRequest first = request('stable-key');
        List<OrgMonitorNotificationService.DispatchResult> firstResults =
            OrgMonitorNotificationService.send(first);
        List<OrgMonitorNotificationService.DispatchResult> secondResults =
            OrgMonitorNotificationService.send(request('stable-key'));

        System.assertEquals('QUEUED', firstResults[1].state);
        System.assertEquals('DUPLICATE', secondResults[1].state);
        System.assertEquals(1, [SELECT count() FROM Governance_Notification__c]);
    }

    @IsTest static void validatesRequiredMessage() {
        Boolean thrown = false;
        try {
            OrgMonitorNotificationService.send(new OrgMonitorNotificationService.NotificationRequest());
        } catch (OrgMonitorNotificationService.OrgMonitorNotificationException error) {
            thrown = true;
        }
        System.assert(thrown);
    }

    private static OrgMonitorNotificationService.NotificationRequest request(String key) {
        OrgMonitorNotificationService.NotificationRequest request =
            new OrgMonitorNotificationService.NotificationRequest();
        request.title = 'Setup changes detected';
        request.message = 'A completed message.';
        request.actorIdentifier = 'admin@example.com';
        request.changeCount = 1;
        request.idempotencyKey = key;
        return request;
    }
}