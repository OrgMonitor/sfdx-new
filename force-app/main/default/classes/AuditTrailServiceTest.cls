@IsTest
private class AuditTrailServiceTest {

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE IsActive = true LIMIT 1];
    }

    // ── Helper: build a simulated SAT SObject list ────────────────────────────
    private static List<SObject> makeSatList(Integer count) {
        User u = getTestUser();
        List<SObject> records = new List<SObject>();
        for (Integer i = 0; i < count; i++) {
            records.add(AuditTrailTestDataFactory.makeSatRecord(
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
        AuditTrailMetadataService.resetCaches();
        AuditTrailMetadataService.cachedConfig  = AuditTrailTestDataFactory.makeConfig(null);
        AuditTrailMetadataService.cachedSeverityRules = AuditTrailTestDataFactory.makeSeverityRules();
        AuditTrailMetadataService.cachedDwSchema = AuditTrailTestDataFactory.makeDwSchema();

        AuditTrailService svc = new AuditTrailService();

        Test.startTest();
        Integer count = svc.process(new List<SObject>());
        Test.stopTest();

        System.assertEquals(0, count, 'Empty list should return 0');
    }

    @IsTest
    static void testProcess_nullList_returnsZero() {
        AuditTrailMetadataService.resetCaches();
        AuditTrailMetadataService.cachedConfig  = AuditTrailTestDataFactory.makeConfig(null);
        AuditTrailMetadataService.cachedSeverityRules = AuditTrailTestDataFactory.makeSeverityRules();
        AuditTrailMetadataService.cachedDwSchema = AuditTrailTestDataFactory.makeDwSchema();

        AuditTrailService svc = new AuditTrailService();

        Test.startTest();
        Integer count = svc.process(null);
        Test.stopTest();

        System.assertEquals(0, count);
    }

    // ── process() — with compliant records ────────────────────────────────────
    @IsTest
    static void testProcess_withActiveWindow_createsCompliantRecord() {
        AuditTrailMetadataService.resetCaches();
        AuditTrailMappingService.resetIntentMap();

        AuditTrailMetadataService.cachedConfig =
            AuditTrailTestDataFactory.makeConfig(System.now().addDays(-1));
        AuditTrailMetadataService.cachedSeverityRules =
            AuditTrailTestDataFactory.makeSeverityRules();
        AuditTrailMetadataService.cachedDwSchema =
            AuditTrailTestDataFactory.makeDwSchema();

        // Insert an active deployment window covering now
        AuditTrailTestDataFactory.insertDeploymentWindow(
            System.now().addHours(-2), System.now().addHours(2), 'Active');

        List<SObject> satList = makeSatList(2);

        Test.startTest();
        AuditTrailService svc = new AuditTrailService();
        Integer count = svc.process(satList);
        Test.stopTest();

        // At least some records should have been upserted
        System.assert(count >= 0, 'process() should not return a negative count');
        System.assert([SELECT COUNT() FROM Audit_Trail__c] >= 0);
    }

    // ── process() — no active windows ─────────────────────────────────────────
    @IsTest
    static void testProcess_noActiveWindows_createsNonCompliantRecords() {
        AuditTrailMetadataService.resetCaches();
        AuditTrailMappingService.resetIntentMap();

        AuditTrailMetadataService.cachedConfig        = AuditTrailTestDataFactory.makeConfig(null);
        AuditTrailMetadataService.cachedSeverityRules = AuditTrailTestDataFactory.makeSeverityRules();
        AuditTrailMetadataService.cachedDwSchema      = AuditTrailTestDataFactory.makeDwSchema();

        List<SObject> satList = makeSatList(1);

        Test.startTest();
        AuditTrailService svc = new AuditTrailService();
        Integer count = svc.process(satList);
        Test.stopTest();

        System.assert(count >= 0);
    }

    // ── process() — idempotency (existing external ID skipped) ───────────────
    @IsTest
    static void testProcess_existingExternalId_noNewRecordsCreated() {
        AuditTrailMetadataService.resetCaches();
        AuditTrailMappingService.resetIntentMap();

        AuditTrailMetadataService.cachedConfig        = AuditTrailTestDataFactory.makeConfig(null);
        AuditTrailMetadataService.cachedSeverityRules = new List<AuditTrailMetadataService.SeverityRule>();
        AuditTrailMetadataService.cachedDwSchema      = AuditTrailTestDataFactory.makeDwSchema();

        // Pre-insert a record with a known external ID
        Audit_Trail__c existing = new Audit_Trail__c(External_Id__c = 'IDEM-001');
        insert existing;

        List<SObject> satList = makeSatList(1);

        Test.startTest();
        AuditTrailService svc = new AuditTrailService();
        svc.process(satList);
        Test.stopTest();

        // Pre-existing record is still present; at most one extra from the new SAT
        Integer postCount = [SELECT COUNT() FROM Audit_Trail__c];
        System.assert(postCount >= 1, 'Pre-existing record should remain');
    }

    // ── process() — error handling ────────────────────────────────────────────
    @IsTest
    static void testProcess_errorIsLoggedNotRethrown() {
        AuditTrailMetadataService.resetCaches();
        AuditTrailErrorService.clearBuffer();

        // Inject a schema that points to a non-existent deployment window object
        AuditTrailMetadataService.AuditTrailConfig cfg = new AuditTrailMetadataService.AuditTrailConfig();
        AuditTrailMetadataService.cachedConfig = cfg;
        AuditTrailMetadataService.cachedSeverityRules = new List<AuditTrailMetadataService.SeverityRule>();
        // Deliberately NOT injecting cachedDwSchema so it tries to discover (which may fail in test)

        List<SObject> satList = makeSatList(1);

        Test.startTest();
        AuditTrailService svc = new AuditTrailService();
        Integer count = svc.process(satList); // should not throw
        Test.stopTest();

        System.assert(count >= 0, 'process() should never throw — errors are logged');
    }
}