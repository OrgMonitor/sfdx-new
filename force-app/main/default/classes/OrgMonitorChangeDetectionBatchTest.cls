@IsTest
private class OrgMonitorChangeDetectionBatchTest {
    @IsTest static void successfulZeroEligibleRunAdvancesWatermarkWithoutDelivery() {
        Datetime prior = System.now().addMinutes(-1);
        insert new ChangeLogRuntime__c(SetupOwnerId = UserInfo.getOrganizationId(),
            Initial_Run_Window__c = 15, Last_Run_Timestamp__c = prior,
            Slack_Notifications_Enabled__c = false,
            Teams_Notifications_Enabled__c = false);
        Test.startTest();
        Database.executeBatch(new OrgMonitorChangeDetectionBatch(), 200);
        Test.stopTest();
        System.assert(ChangeLogRuntime__c.getOrgDefaults().Last_Run_Timestamp__c > prior);
        System.assertEquals(0, [SELECT COUNT() FROM Governance_Notification__c]);
    }

    @IsTest static void missingHistoricalWindowFailsBeforeCheckpoint() {
        insert new ChangeLogRuntime__c(SetupOwnerId = UserInfo.getOrganizationId());
        Boolean failed = false;
        try { OrgMonitorChangeRunConfig.load(System.now()); }
        catch (OrgMonitorChangeRunConfig.ConfigurationException error) { failed = true; }
        System.assertEquals(true, failed);
        System.assertEquals(null, ChangeLogRuntime__c.getOrgDefaults().Last_Run_Timestamp__c);
    }

    @IsTest static void firstRunUsesConfiguredHistoricalWindowOnly() {
        insert new ChangeLogRuntime__c(SetupOwnerId = UserInfo.getOrganizationId(),
            Initial_Run_Window__c = 45, Last_Run_Timestamp__c = null,
            Slack_Notifications_Enabled__c = false,
            Teams_Notifications_Enabled__c = false);
        Datetime cutoff = Datetime.newInstanceGMT(2026, 9, 5, 6, 45, 0);
        OrgMonitorChangeRunConfig config = OrgMonitorChangeRunConfig.load(cutoff);
        System.assertEquals(null, config.previousWatermark);
        System.assertEquals(45, config.historicalDays);
        System.assertEquals(cutoff.addDays(-45), config.lowerBoundary,
            'A first run must use the App Setup historical timeframe, not legacy custom metadata.');
    }

    @IsTest static void invalidNotificationSetupIsHandledWithoutNativeBatchFailure() {
        insert new ChangeLogRuntime__c(SetupOwnerId = UserInfo.getOrganizationId(),
            Initial_Run_Window__c = 15, Teams_Notifications_Enabled__c = true,
            Teams_Team_Id__c = 'team', Teams_Channel_Id__c = 'channel');
        Test.startTest();
        Id jobId = Database.executeBatch(new OrgMonitorChangeDetectionBatch(), 200);
        Test.stopTest();
        AsyncApexJob job = [SELECT Status, NumberOfErrors FROM AsyncApexJob WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status,
            'Catchable startup errors should use the branded email rather than native exception mail.');
        System.assertEquals(0, job.NumberOfErrors);
        System.assertEquals(null, ChangeLogRuntime__c.getOrgDefaults().Last_Run_Timestamp__c,
            'Handled configuration failure must not advance the watermark.');
    }

    @IsTest static void schedulerStartsReplacementBatch() {
        Datetime prior = System.now().addMinutes(-1);
        insert new ChangeLogRuntime__c(SetupOwnerId = UserInfo.getOrganizationId(),
            Initial_Run_Window__c = 15, Last_Run_Timestamp__c = prior,
            Slack_Notifications_Enabled__c = false,
            Teams_Notifications_Enabled__c = false);

        Test.startTest();
        new OrgMonitorChangeDetectionScheduler().execute(null);
        Test.stopTest();

        System.assert(ChangeLogRuntime__c.getOrgDefaults().Last_Run_Timestamp__c > prior,
            'The scheduled batch must checkpoint a successful empty run.');
    }
}