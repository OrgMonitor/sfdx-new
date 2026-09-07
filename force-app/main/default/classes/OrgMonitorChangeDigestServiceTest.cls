@IsTest
private class OrgMonitorChangeDigestServiceTest {
    private class ProviderMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse(); response.setStatusCode(200);
            response.setBody(request.getEndpoint().contains('Slack')
                ? '{"ok":true,"ts":"1"}' : '{"id":"1"}');
            return response;
        }
    }

    private static Change_Log__c change(String sourceId, String runId,
            String severity, Boolean nonCompliant) {
        return new Change_Log__c(External_Id__c = sourceId,
            Effective_Actor__c = UserInfo.getUserId(), Changed_By_User__c = UserInfo.getUserId(),
            Log_Created_Date__c = System.now(), Severity__c = severity,
            Non_Compliant__c = nonCompliant, Run_Correlation_Id__c = runId,
            Change_Summary__c = 'Updated PermissionSet “Service User”. Performed by Test User.',
            Compliance_Reason__c = nonCompliant
                ? 'Non-compliant — No deployment window covered the change time.'
                : 'Compliant — Change occurred during an approved deployment window.');
    }

    @IsTest static void zeroChangeCreatesNoDelivery() {
        insert new ChangeLogRuntime__c(SetupOwnerId = UserInfo.getOrganizationId(),
            Slack_Notifications_Enabled__c = false, Teams_Notifications_Enabled__c = false);
        OrgMonitorChangeDigestService.dispatch('OM-NONE', System.now().addHours(-1), System.now());
        System.assertEquals(0, [SELECT COUNT() FROM Governance_Notification__c]);
    }

    @IsTest static void groupsByActorAndUsesExistingProviderService() {
        insert new ChangeLogRuntime__c(SetupOwnerId = UserInfo.getOrganizationId(),
            Slack_Notifications_Enabled__c = true, Slack_Channel_Id__c = 'C1',
            Slack_Last_Test__c = System.now(), Teams_Notifications_Enabled__c = true,
            Teams_Team_Id__c = 'T1', Teams_Channel_Id__c = 'CH1', Teams_Last_Test__c = System.now());
        insert new List<Change_Log__c>{
            change('0Ym000000000011', 'OM-DIGEST', 'CRITICAL', true),
            change('0Ym000000000012', 'OM-DIGEST', 'HIGH', false)
        };
        Test.setMock(HttpCalloutMock.class, new ProviderMock());
        Test.startTest();
        OrgMonitorChangeDigestService.dispatch('OM-DIGEST', System.now().addHours(-1), System.now());
        Test.stopTest();
        List<Governance_Notification__c> deliveries = [
            SELECT Provider__c, Title__c, Message__c, Content_Format__c, Fallback_Text__c,
                   Actor_Identifier__c, Change_Count__c, Status__c
            FROM Governance_Notification__c
        ];
        System.assertEquals(2, deliveries.size());
        for (Governance_Notification__c delivery : deliveries) {
            System.assertEquals('🚨 Org Monitor — Critical changes require review',
                delivery.Title__c);
            if (delivery.Provider__c == 'Slack') {
                System.assertEquals('SLACK_BLOCKS', delivery.Content_Format__c);
                System.assert(delivery.Fallback_Text__c.contains('Org Monitor detected'));
                System.assert(delivery.Message__c.contains('CRITICAL NON-COMPLIANT CHANGES'));
            } else {
                System.assertEquals('TEAMS_HTML', delivery.Content_Format__c);
                System.assert(delivery.Message__c.contains('<br>'));
                System.assert(delivery.Message__c.contains('CRITICAL NON-COMPLIANT CHANGES'));
            }
            System.assertEquals(String.valueOf(UserInfo.getUserId()), delivery.Actor_Identifier__c);
            System.assertEquals(2, delivery.Change_Count__c);
            System.assertEquals('Sent', delivery.Status__c);
        }
    }

    @IsTest static void stableKeyPreventsRepeatedDigestDelivery() {
        insert new ChangeLogRuntime__c(SetupOwnerId = UserInfo.getOrganizationId(),
            Slack_Notifications_Enabled__c = true, Slack_Channel_Id__c = 'C1',
            Slack_Last_Test__c = System.now(), Teams_Notifications_Enabled__c = false);
        insert change('0Ym000000000013', 'OM-IDEMPOTENT', 'LOW', false);
        Datetime startAt = System.now().addHours(-1), endAt = System.now();
        OrgMonitorChangeDigestService.dispatch('OM-IDEMPOTENT', startAt, endAt);
        OrgMonitorChangeDigestService.dispatch('OM-IDEMPOTENT', startAt, endAt);
        System.assertEquals(1, [SELECT COUNT() FROM Governance_Notification__c]);
    }
}