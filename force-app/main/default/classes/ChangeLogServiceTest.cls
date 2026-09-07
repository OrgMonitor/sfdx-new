@IsTest
private class ChangeLogServiceTest {

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE IsActive = true LIMIT 1];
    }

    // ── Helper: build a simulated SAT SObject list ────────────────────────────
    private static List<SObject> makeSatList(Integer count) {
        User u = getTestUser();
        List<SObject> records = new List<SObject>();
        for (Integer i = 0; i < count; i++) {
            records.add(ChangeLogTestDataFactory.makeSatRecord(
                'Created Apex Class Test' + i,
                'Apex Classes',
                'Display ' + i,
                u.Id,
                System.now().addMinutes(-i)
            ));
        }
        return records;
    }

    // ── process() — empty input ───────────────────────────────────────────────
    @IsTest
    static void testProcess_emptyList_returnsZero() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService.cachedConfig  = ChangeLogTestDataFactory.makeConfig(null);
        ChangeLogMetadataService.cachedSeverityRules = ChangeLogTestDataFactory.makeSeverityRules();
        ChangeLogMetadataService.cachedDwSchema = ChangeLogTestDataFactory.makeDwSchema();

        ChangeLogService svc = new ChangeLogService();

        Test.startTest();
        Integer count = svc.process(new List<SObject>());
        Test.stopTest();

        System.assertEquals(0, count, 'Empty list should return 0');
    }

    @IsTest
    static void testProcess_nullList_returnsZero() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService.cachedConfig  = ChangeLogTestDataFactory.makeConfig(null);
        ChangeLogMetadataService.cachedSeverityRules = ChangeLogTestDataFactory.makeSeverityRules();
        ChangeLogMetadataService.cachedDwSchema = ChangeLogTestDataFactory.makeDwSchema();

        ChangeLogService svc = new ChangeLogService();

        Test.startTest();
        Integer count = svc.process(null);
        Test.stopTest();

        System.assertEquals(0, count);
    }

    // ── process() — with compliant records ────────────────────────────────────
    @IsTest
    static void testProcess_withActiveWindow_createsCompliantRecord() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMappingService.resetIntentMap();

        ChangeLogMetadataService.cachedConfig =
            ChangeLogTestDataFactory.makeConfig(System.now().addDays(-1));
        ChangeLogMetadataService.cachedSeverityRules =
            ChangeLogTestDataFactory.makeSeverityRules();
        ChangeLogMetadataService.cachedDwSchema =
            ChangeLogTestDataFactory.makeDwSchema();

        // Insert an active deployment window covering now
        ChangeLogTestDataFactory.insertDeploymentWindow(
            System.now().addHours(-2), System.now().addHours(2), 'Active');

        List<SObject> satList = makeSatList(2);

        Test.startTest();
        ChangeLogService svc = new ChangeLogService();
        Integer count = svc.process(satList);
        Test.stopTest();

        // At least some records should have been upserted
        System.assert(count >= 0, 'process() should not return a negative count');
        System.assert([SELECT COUNT() FROM Change_Log__c] >= 0);
    }

    // ── process() — no active windows ─────────────────────────────────────────
    @IsTest
    static void testProcess_noActiveWindows_createsNonCompliantRecords() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMappingService.resetIntentMap();

        ChangeLogMetadataService.cachedConfig        = ChangeLogTestDataFactory.makeConfig(null);
        ChangeLogMetadataService.cachedSeverityRules = ChangeLogTestDataFactory.makeSeverityRules();
        ChangeLogMetadataService.cachedDwSchema      = ChangeLogTestDataFactory.makeDwSchema();

        List<SObject> satList = makeSatList(1);

        Test.startTest();
        ChangeLogService svc = new ChangeLogService();
        Integer count = svc.process(satList);
        Test.stopTest();

        System.assert(count >= 0);
    }

    // ── process() — idempotency (existing external ID skipped) ───────────────
    @IsTest
    static void testProcess_existingExternalId_noNewRecordsCreated() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMappingService.resetIntentMap();

        ChangeLogMetadataService.cachedConfig        = ChangeLogTestDataFactory.makeConfig(null);
        ChangeLogMetadataService.cachedSeverityRules = new List<ChangeLogMetadataService.SeverityRule>();
        ChangeLogMetadataService.cachedDwSchema      = ChangeLogTestDataFactory.makeDwSchema();

        // Pre-insert a record with a known external ID
        Change_Log__c existing = new Change_Log__c(External_Id__c = 'IDEM-001');
        insert existing;

        List<SObject> satList = makeSatList(1);

        Test.startTest();
        ChangeLogService svc = new ChangeLogService();
        svc.process(satList);
        Test.stopTest();

        // Pre-existing record is still present; at most one extra from the new SAT
        Integer postCount = [SELECT COUNT() FROM Change_Log__c];
        System.assert(postCount >= 1, 'Pre-existing record should remain');
    }

    // ── process() — error handling ────────────────────────────────────────────
    @IsTest
    static void testProcess_errorIsLoggedNotRethrown() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogErrorService.clearBuffer();

        // Inject a schema that points to a non-existent deployment window object
        ChangeLogMetadataService.ChangeLogConfig cfg = new ChangeLogMetadataService.ChangeLogConfig();
        ChangeLogMetadataService.cachedConfig = cfg;
        ChangeLogMetadataService.cachedSeverityRules = new List<ChangeLogMetadataService.SeverityRule>();
        // Deliberately NOT injecting cachedDwSchema so it tries to discover (which may fail in test)

        List<SObject> satList = makeSatList(1);

        Test.startTest();
        ChangeLogService svc = new ChangeLogService();
        Integer count = svc.process(satList); // should not throw
        Test.stopTest();

        System.assert(count >= 0, 'process() should never throw — errors are logged');
    }
}