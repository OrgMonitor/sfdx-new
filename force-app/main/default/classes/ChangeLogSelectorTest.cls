@IsTest
private class ChangeLogSelectorTest {

    // ── getSetupChangeLogLocator() ───────────────────────────────────────────
    @IsTest
    static void testGetLocator_withLastRunTimestamp_returnsLocator() {
        ChangeLogSelector selector = new ChangeLogSelector();
        DateTime lastRun = System.now().addDays(-1);

        Test.startTest();
        Database.QueryLocator locator = selector.getSetupChangeLogLocator(lastRun);
        Test.stopTest();

        System.assertNotEquals(null, locator,
            'Query locator should not be null when lastRun is provided');
    }

    @IsTest
    static void testGetLocator_withNullLastRun_returnsLocatorForLookback() {
        ChangeLogSelector selector = new ChangeLogSelector();

        Test.startTest();
        Database.QueryLocator locator = selector.getSetupChangeLogLocator(null);
        Test.stopTest();

        System.assertNotEquals(null, locator,
            'Query locator should not be null with null lastRun (uses lookback)');
    }

    // ── getActiveDeploymentWindows() ──────────────────────────────────────────
    @IsTest
    static void testGetActiveDeploymentWindows_returnsActiveOnly() {
        DateTime now = System.now();
        Deployment_Window__c active =
            ChangeLogTestDataFactory.insertDeploymentWindow(
                now.addHours(-1), now.addHours(1), 'Active');
        Deployment_Window__c closed =
            ChangeLogTestDataFactory.insertDeploymentWindow(
                now.addHours(-5), now.addHours(-3), 'Closed');

        ChangeLogMetadataService.DeploymentWindowSchema dwSchema =
            ChangeLogTestDataFactory.makeDwSchema();

        ChangeLogSelector selector = new ChangeLogSelector();

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
        ChangeLogSelector selector = new ChangeLogSelector();
        List<SObject> windows = selector.getActiveDeploymentWindows(null);
        System.assert(windows.isEmpty(), 'Null schema should return empty list');
    }

    // ── getExistingExternalIds() ──────────────────────────────────────────────
    @IsTest
    static void testGetExistingExternalIds_returnsMatchingIds() {
        Change_Log__c at = new Change_Log__c(External_Id__c = 'SAT-TEST-001');
        insert at;

        ChangeLogSelector selector = new ChangeLogSelector();

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
        ChangeLogSelector selector = new ChangeLogSelector();
        Set<String> existing = selector.getExistingExternalIds(new Set<String>());
        System.assert(existing.isEmpty());
    }

    @IsTest
    static void testGetExistingExternalIds_nullInputReturnsEmpty() {
        ChangeLogSelector selector = new ChangeLogSelector();
        Set<String> existing = selector.getExistingExternalIds(null);
        System.assert(existing.isEmpty());
    }
}