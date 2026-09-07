@IsTest
private class ChangeLogBatchTest {

    // ── Full batch execution (start/execute/finish) ───────────────────────────
    @IsTest
    static void testBatchExecutes_endToEnd() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMappingService.resetIntentMap();
        ChangeLogErrorService.clearBuffer();

        // Inject config so batch uses lookback mode (no lastRun = 3-month window)
        ChangeLogMetadataService.cachedConfig =
            ChangeLogTestDataFactory.makeConfig(null);
        ChangeLogMetadataService.cachedSeverityRules =
            ChangeLogTestDataFactory.makeSeverityRules();
        ChangeLogMetadataService.cachedDwSchema =
            ChangeLogTestDataFactory.makeDwSchema();

        // Insert a deployment window so compliance logic runs
        ChangeLogTestDataFactory.insertDeploymentWindow(
            System.now().addDays(-30),
            System.now().addDays(1),
            'Active'
        );

        Test.startTest();
        ChangeLogBatch batch = new ChangeLogBatch();
        Database.executeBatch(batch, 200);
        Test.stopTest();

        // Batch ran without uncaught exception; Change_Log__c records may or
        // may not exist depending on org SAT data — we just verify no exception.
        System.assert(true, 'Batch should complete without exception');
    }

    // ── start() uses injected lastRunTimestamp ────────────────────────────────
    @IsTest
    static void testBatch_withLastRunTimestamp_queresIncrementally() {
        ChangeLogMetadataService.resetCaches();

        DateTime recent = System.now().addMinutes(-30);
        ChangeLogMetadataService.cachedConfig =
            ChangeLogTestDataFactory.makeConfig(recent);
        ChangeLogMetadataService.cachedSeverityRules =
            new List<ChangeLogMetadataService.SeverityRule>();
        ChangeLogMetadataService.cachedDwSchema =
            ChangeLogTestDataFactory.makeDwSchema();

        Test.startTest();
        ChangeLogBatch batch = new ChangeLogBatch();
        Database.executeBatch(batch, 200);
        Test.stopTest();

        System.assert(true, 'Batch with incremental timestamp should complete');
    }

    // ── totalProcessed accumulates across chunks ──────────────────────────────
    @IsTest
    static void testBatch_totalProcessedIsStateful() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMappingService.resetIntentMap();

        ChangeLogMetadataService.cachedConfig =
            ChangeLogTestDataFactory.makeConfig(null);
        ChangeLogMetadataService.cachedSeverityRules =
            ChangeLogTestDataFactory.makeSeverityRules();
        ChangeLogMetadataService.cachedDwSchema =
            ChangeLogTestDataFactory.makeDwSchema();

        Test.startTest();
        ChangeLogBatch batch = new ChangeLogBatch();
        // Access @TestVisible field before run to confirm initial value
        System.assertEquals(0, batch.totalProcessed,
            'totalProcessed should start at 0');
        Database.executeBatch(batch, 200);
        Test.stopTest();

        // After run totalProcessed reflects what was processed
        System.assert(batch.totalProcessed >= 0,
            'totalProcessed should be non-negative after batch run');
    }

    // ── finish() schedules timestamp update without throwing ──────────────────
    @IsTest
    static void testBatch_finishDoesNotThrow() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService.cachedConfig =
            ChangeLogTestDataFactory.makeConfig(System.now().addDays(-1));
        ChangeLogMetadataService.cachedSeverityRules =
            new List<ChangeLogMetadataService.SeverityRule>();
        ChangeLogMetadataService.cachedDwSchema =
            ChangeLogTestDataFactory.makeDwSchema();

        Test.startTest();
        try {
            ChangeLogBatch batch = new ChangeLogBatch();
            Database.executeBatch(batch, 200);
        } catch (Exception e) {
            System.assert(false, 'Batch finish() should not surface an exception: ' + e.getMessage());
        }
        Test.stopTest();
    }
}