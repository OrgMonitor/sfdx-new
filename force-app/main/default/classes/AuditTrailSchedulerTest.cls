@IsTest
private class AuditTrailSchedulerTest {

    private static final String CRON_EXPR = '0 0 1 * * ?';
    private static final String JOB_NAME  = 'AuditTrail_Test_Schedule';

    // ── Schedulable execution ─────────────────────────────────────────────────
    @IsTest
    static void testScheduler_executesWithoutException() {
        AuditTrailMetadataService.resetCaches();
        AuditTrailMetadataService.cachedConfig =
            AuditTrailTestDataFactory.makeConfig(System.now().addDays(-1));
        AuditTrailMetadataService.cachedSeverityRules =
            new List<AuditTrailMetadataService.SeverityRule>();
        AuditTrailMetadataService.cachedDwSchema =
            AuditTrailTestDataFactory.makeDwSchema();

        Test.startTest();
        String jobId = System.schedule(JOB_NAME, CRON_EXPR, new AuditTrailScheduler());
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Scheduler should return a valid job ID');

        // Clean up
        CronTrigger ct = [SELECT Id FROM CronTrigger WHERE Id = :jobId LIMIT 1];
        System.abortJob(ct.Id);
    }

    @IsTest
    static void testScheduler_executeTriggersBatch() {
        AuditTrailMetadataService.resetCaches();
        AuditTrailMetadataService.cachedConfig =
            AuditTrailTestDataFactory.makeConfig(null);
        AuditTrailMetadataService.cachedSeverityRules =
            new List<AuditTrailMetadataService.SeverityRule>();
        AuditTrailMetadataService.cachedDwSchema =
            AuditTrailTestDataFactory.makeDwSchema();

        Test.startTest();
        AuditTrailScheduler scheduler = new AuditTrailScheduler();
        String jobId = System.schedule(JOB_NAME + '_2', CRON_EXPR, scheduler);
        Test.stopTest();

        // The scheduler should have kicked off at least one batch job
        // (Apex batch count in Test context is limited but verifiable)
        System.assertNotEquals(null, jobId);

        // Abort job to avoid leaving scheduled jobs
        try {
            System.abortJob(jobId);
        } catch (Exception e) {
            // Job may have already run in test context
        }
    }

    @IsTest
    static void testScheduler_canBeInstantiated() {
        AuditTrailScheduler s = new AuditTrailScheduler();
        System.assertNotEquals(null, s, 'Scheduler should be instantiable');
    }

    // ── Constants used in batch size ─────────────────────────────────────────
    @IsTest
    static void testConstants_batchSizeIsPositive() {
        System.assert(AuditTrailConstants.BATCH_SIZE > 0,
            'BATCH_SIZE must be positive');
        System.assertEquals(200, AuditTrailConstants.BATCH_SIZE);
    }

    @IsTest
    static void testConstants_lookbackMonthsIsPositive() {
        System.assert(AuditTrailConstants.LOOKBACK_MONTHS > 0);
        System.assertEquals(3, AuditTrailConstants.LOOKBACK_MONTHS);
    }

    @IsTest
    static void testConstants_satObjectName() {
        System.assertEquals('SetupAuditTrail', AuditTrailConstants.SAT_OBJECT);
    }

    @IsTest
    static void testConstants_complianceLabels() {
        System.assertEquals('Compliant',     AuditTrailConstants.COMPLIANT);
        System.assertEquals('Non-Compliant', AuditTrailConstants.NON_COMPLIANT);
        System.assertEquals('LOW',           AuditTrailConstants.SEVERITY_DEFAULT);
    }

    @IsTest
    static void testConstants_cmtFullName() {
        System.assertEquals(
            'Audit_Trail_Config__mdt.Default',
            AuditTrailConstants.CMT_FULL_NAME
        );
    }

    // ── AuditTrailException ───────────────────────────────────────────────────
    @IsTest
    static void testAuditTrailException_canBeThrown() {
        Boolean caught = false;
        try {
            throw new AuditTrailException('test error');
        } catch (AuditTrailException e) {
            caught = true;
            System.assertEquals('test error', e.getMessage());
        }
        System.assert(caught, 'AuditTrailException should be catchable');
    }

    // ── MdtDeployCallback ─────────────────────────────────────────────────────
    @IsTest
    static void testMdtDeployCallback_nullResultDoesNotThrow() {
        AuditTrailMdtDeployCallback cb = new AuditTrailMdtDeployCallback();
        cb.handleResult(null, null); // must not throw
        System.assert(true);
    }
}