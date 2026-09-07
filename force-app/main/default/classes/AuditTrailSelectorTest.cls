@IsTest
private class AuditTrailSelectorTest {

    // ── getSetupAuditTrailLocator() ───────────────────────────────────────────
    @IsTest
    static void testGetLocator_withLastRunTimestamp_returnsLocator() {
        AuditTrailSelector selector = new AuditTrailSelector();
        DateTime lastRun = System.now().addDays(-1);

        Test.startTest();
        Database.QueryLocator locator = selector.getSetupAuditTrailLocator(lastRun);
        Test.stopTest();

        System.assertNotEquals(null, locator,
            'Query locator should not be null when lastRun is provided');
    }

    @IsTest
    static void testGetLocator_withNullLastRun_returnsLocatorForLookback() {
        AuditTrailSelector selector = new AuditTrailSelector();

        Test.startTest();
        Database.QueryLocator locator = selector.getSetupAuditTrailLocator(null);
        Test.stopTest();

        System.assertNotEquals(null, locator,
            'Query locator should not be null with null lastRun (uses lookback)');
    }

    // ── getActiveDeploymentWindows() ──────────────────────────────────────────
    @IsTest
    static void testGetActiveDeploymentWindows_returnsActiveOnly() {
        DateTime now = System.now();
        Deployment_Window__c active =
            AuditTrailTestDataFactory.insertDeploymentWindow(
                now.addHours(-1), now.addHours(1), 'Active');
        Deployment_Window__c closed =
            AuditTrailTestDataFactory.insertDeploymentWindow(
                now.addHours(-5), now.addHours(-3), 'Closed');

        AuditTrailMetadataService.DeploymentWindowSchema dwSchema =
            AuditTrailTestDataFactory.makeDwSchema();

        AuditTrailSelector selector = new AuditTrailSelector();

        Test.startTest();
        List<SObject> windows = selector.getActiveDeploymentWindows(dwSchema);
        Test.stopTest();

        Boolean foundActive = false;
        Boolean foundClosed = false;
        for (SObject dw : windows) {
            if ((Id) dw.get('Id') == active.Id) foundActive = true;
            if ((Id) dw.get('Id') == closed.Id) foundClosed = true;
        }
        System.assert(foundActive,  'Active window should be returned');
        System.assert(!foundClosed, 'Closed window should NOT be returned');
    }

    @IsTest
    static void testGetActiveDeploymentWindows_nullSchemaReturnsEmpty() {
        AuditTrailSelector selector = new AuditTrailSelector();
        List<SObject> windows = selector.getActiveDeploymentWindows(null);
        System.assert(windows.isEmpty(), 'Null schema should return empty list');
    }

    // ── getExistingExternalIds() ──────────────────────────────────────────────
    @IsTest
    static void testGetExistingExternalIds_returnsMatchingIds() {
        Audit_Trail__c at = new Audit_Trail__c(External_Id__c = 'SAT-TEST-001');
        insert at;

        AuditTrailSelector selector = new AuditTrailSelector();

        Test.startTest();
        Set<String> existing = selector.getExistingExternalIds(
            new Set<String>{ 'SAT-TEST-001', 'SAT-TEST-999' });
        Test.stopTest();

        System.assert(existing.contains('SAT-TEST-001'),
            'Should find the existing external ID');
        System.assert(!existing.contains('SAT-TEST-999'),
            'Should not find a non-existent external ID');
    }

    @IsTest
    static void testGetExistingExternalIds_emptyInputReturnsEmpty() {
        AuditTrailSelector selector = new AuditTrailSelector();
        Set<String> existing = selector.getExistingExternalIds(new Set<String>());
        System.assert(existing.isEmpty());
    }

    @IsTest
    static void testGetExistingExternalIds_nullInputReturnsEmpty() {
        AuditTrailSelector selector = new AuditTrailSelector();
        Set<String> existing = selector.getExistingExternalIds(null);
        System.assert(existing.isEmpty());
    }
}