@IsTest
private class ChangeLogMetadataServiceTest {

    // ── getConfig() ───────────────────────────────────────────────────────────
    @IsTest
    static void testGetConfig_returnsCachedConfigAfterFirstLoad() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService svc = new ChangeLogMetadataService();

        Test.startTest();
        ChangeLogMetadataService.ChangeLogConfig cfg1 = svc.getConfig();
        ChangeLogMetadataService.ChangeLogConfig cfg2 = svc.getConfig();
        Test.stopTest();

        // Both calls return the same instance (cache hit on second call)
        System.assertNotEquals(null, cfg1, 'Config should never be null');
        System.assertEquals(cfg1, cfg2, 'Second call should return cached instance');
    }

    @IsTest
    static void testGetConfig_injectedCacheIsUsed() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService.ChangeLogConfig injected =
            ChangeLogTestDataFactory.makeConfig(System.now().addDays(-1));

        // Inject via @TestVisible static
        ChangeLogMetadataService.cachedConfig = injected;

        ChangeLogMetadataService svc = new ChangeLogMetadataService();
        ChangeLogMetadataService.ChangeLogConfig result = svc.getConfig();

        System.assertEquals(injected.lastRunTimestamp, result.lastRunTimestamp,
            'Should return injected config without re-querying');
    }

    // ── getSeverityRules() ────────────────────────────────────────────────────
    @IsTest
    static void testGetSeverityRules_returnsCachedRules() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService.cachedSeverityRules =
            ChangeLogTestDataFactory.makeSeverityRules();

        ChangeLogMetadataService svc = new ChangeLogMetadataService();
        List<ChangeLogMetadataService.SeverityRule> rules = svc.getSeverityRules();

        System.assertEquals(3, rules.size(), 'Should return injected 3 rules');
        System.assertEquals('CRITICAL', rules[0].severityValue);
    }

    @IsTest
    static void testGetSeverityRules_liveQueryRunsWithoutError() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService svc = new ChangeLogMetadataService();

        Test.startTest();
        List<ChangeLogMetadataService.SeverityRule> rules = svc.getSeverityRules();
        Test.stopTest();

        // We can't assert on content (depends on org data) but it must not throw
        System.assertNotEquals(null, rules, 'Rules list must not be null');
    }

    // ── getDeploymentWindowSchema() ───────────────────────────────────────────
    @IsTest
    static void testGetDeploymentWindowSchema_discoversRealFields() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService svc = new ChangeLogMetadataService();

        Test.startTest();
        ChangeLogMetadataService.DeploymentWindowSchema schema =
            svc.getDeploymentWindowSchema();
        Test.stopTest();

        System.assertNotEquals(null, schema, 'Schema should be discovered');
        System.assertEquals('Deployment_Window__c', schema.objectApiName);
        System.assertNotEquals(null, schema.startField,  'Start field must be discovered');
        System.assertNotEquals(null, schema.endField,    'End field must be discovered');
        System.assertNotEquals(null, schema.statusField, 'Status field must be discovered');
    }

    @IsTest
    static void testGetDeploymentWindowSchema_cacheIsUsed() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService.cachedDwSchema =
            ChangeLogTestDataFactory.makeDwSchema();

        ChangeLogMetadataService svc = new ChangeLogMetadataService();
        ChangeLogMetadataService.DeploymentWindowSchema schema =
            svc.getDeploymentWindowSchema();

        System.assertEquals('Start_Date_Time__c', schema.startField);
    }

    // ── getFieldMap() ─────────────────────────────────────────────────────────
    @IsTest
    static void testGetFieldMap_returnsNonEmptyMapForKnownObject() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService svc = new ChangeLogMetadataService();

        Map<String, Schema.SObjectField> fieldMap =
            svc.getFieldMap('Deployment_Window__c');

        System.assert(!fieldMap.isEmpty(), 'Field map should not be empty');
        System.assert(fieldMap.containsKey('start_date_time__c'),
            'Start_Date_Time__c should be present');
    }

    @IsTest
    static void testGetFieldMap_returnsEmptyMapForUnknownObject() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService svc = new ChangeLogMetadataService();

        Map<String, Schema.SObjectField> fieldMap =
            svc.getFieldMap('NonExistent_Object_XYZZY__c');

        System.assertNotEquals(null, fieldMap, 'Should return empty map, not null');
        System.assert(fieldMap.isEmpty(), 'Should be empty for unknown object');
    }

    // ── getCreateableFields() ─────────────────────────────────────────────────
    @IsTest
    static void testGetCreateableFields_filtersAutoNumber() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService svc = new ChangeLogMetadataService();

        List<Schema.DescribeFieldResult> fields =
            svc.getCreateableFields('Change_Log__c');

        System.assert(!fields.isEmpty(), 'Should have at least one createable field');
        for (Schema.DescribeFieldResult dfr : fields) {
            System.assert(dfr.isCreateable(), 'All fields should be createable');
            System.assert(!dfr.isAutoNumber(), 'Auto-number fields should be excluded');
        }
    }

    // ── objectExists() ────────────────────────────────────────────────────────
    @IsTest
    static void testObjectExists_trueForRealObject() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService svc = new ChangeLogMetadataService();
        System.assert(svc.objectExists('Deployment_Window__c'));
    }

    @IsTest
    static void testObjectExists_falseForFakeObject() {
        ChangeLogMetadataService.resetCaches();
        ChangeLogMetadataService svc = new ChangeLogMetadataService();
        System.assert(!svc.objectExists('Fake_Object_ZZZZ__c'));
    }

    // ── resetCaches() ─────────────────────────────────────────────────────────
    @IsTest
    static void testResetCaches_clearsAll() {
        ChangeLogMetadataService.cachedConfig        = new ChangeLogMetadataService.ChangeLogConfig();
        ChangeLogMetadataService.cachedSeverityRules = new List<ChangeLogMetadataService.SeverityRule>();
        ChangeLogMetadataService.cachedDwSchema      = new ChangeLogMetadataService.DeploymentWindowSchema();

        ChangeLogMetadataService.resetCaches();

        System.assertEquals(null, ChangeLogMetadataService.cachedConfig);
        System.assertEquals(null, ChangeLogMetadataService.cachedSeverityRules);
        System.assertEquals(null, ChangeLogMetadataService.cachedDwSchema);
    }
}