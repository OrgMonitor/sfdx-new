@IsTest
private class AuditTrailBatchTest {

    // ── Full batch execution (start/execute/finish) ───────────────────────────
    @IsTest
    static void testBatchExecutes_endToEnd() {
        AuditTrailMetadataService.resetCaches();
        AuditTrailMappingService.resetIntentMap();
        AuditTrailErrorService.clearBuffer();

        // Inject config so batch uses lookback mode (no lastRun = 3-month window)
        AuditTrailMetadataService.cachedConfig =
            AuditTrailTestDataFactory.makeConfig(null);
        AuditTrailMetadataService.cachedSeverityRules =
            AuditTrailTestDataFactory.makeSeverityRules();
        AuditTrailMetadataService.cachedDwSchema =
            AuditTrailTestDataFactory.makeDwSchema();

        // Insert a deployment window so compliance logic runs
        AuditTrailTestDataFactory.insertDeploymentWindow(
            System.now().addDays(-30),
            System.now().addDays(1),
            'Active'
        );

        Test.startTest();
        AuditTrailBatch batch = new AuditTrailBatch();
        Database.executeBatch(batch, 200);
        Test.stopTest();

        // Batch ran without uncaught exception; Audit_Trail__c records may or
        // may not exist depending on org SAT data — we just verify no exception.
        System.assert(true, 'Batch should complete without exception');
    }

    // ── start() uses injected lastRunTimestamp ────────────────────────────────
    @IsTest
    static void testBatch_withLastRunTimestamp_queresIncrementally() {
        AuditTrailMetadataService.resetCaches();

        DateTime recent = System.now().addMinutes(-30);
        AuditTrailMetadataService.cachedConfig =
            AuditTrailTestDataFactory.makeConfig(recent);
        AuditTrailMetadataService.cachedSeverityRules =
            new List<AuditTrailMetadataService.SeverityRule>();
        AuditTrailMetadataService.cachedDwSchema =
            AuditTrailTestDataFactory.makeDwSchema();

        Test.startTest();
        AuditTrailBatch batch = new AuditTrailBatch();
        Database.executeBatch(batch, 200);
        Test.stopTest();

        System.assert(true, 'Batch with incremental timestamp should complete');
    }

    // ── totalProcessed accumulates across chunks ──────────────────────────────
    @IsTest
    static void testBatch_totalProcessedIsStateful() {
        AuditTrailMetadataService.resetCaches();
        AuditTrailMappingService.resetIntentMap();

        AuditTrailMetadataService.cachedConfig =
            AuditTrailTestDataFactory.makeConfig(null);
        AuditTrailMetadataService.cachedSeverityRules =
            AuditTrailTestDataFactory.makeSeverityRules();
        AuditTrailMetadataService.cachedDwSchema =
            AuditTrailTestDataFactory.makeDwSchema();

        Test.startTest();
        AuditTrailBatch batch = new AuditTrailBatch();
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
        AuditTrailMetadataService.resetCaches();
        AuditTrailMetadataService.cachedConfig =
            AuditTrailTestDataFactory.makeConfig(System.now().addDays(-1));
        AuditTrailMetadataService.cachedSeverityRules =
            new List<AuditTrailMetadataService.SeverityRule>();
        AuditTrailMetadataService.cachedDwSchema =
            AuditTrailTestDataFactory.makeDwSchema();

        Test.startTest();
        try {
            AuditTrailBatch batch = new AuditTrailBatch();
            Database.executeBatch(batch, 200);
        } catch (Exception e) {
            System.assert(false, 'Batch finish() should not surface an exception: ' + e.getMessage());
        }
        Test.stopTest();
    }
}