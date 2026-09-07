@IsTest
private class ChangeLogComplianceServiceTest {

    // ── Helpers ───────────────────────────────────────────────────────────────
    private static User testUser;
    private static User getTestUser() {
        if (testUser == null) {
            testUser = [SELECT Id FROM User WHERE IsActive = true LIMIT 1];
        }
        return testUser;
    }

    private static SObject makeSat(Id satId, DateTime createdDate) {
        return ChangeLogTestDataFactory.makeSatRecord(
            'Test Action', 'Test Section', 'Test Display',
            getTestUser().Id, createdDate);
    }

    // ── evaluate() — compliant record ─────────────────────────────────────────
    @IsTest
    static void testEvaluate_recordInsideWindow_isCompliant() {
        DateTime windowStart = System.now().addHours(-2);
        DateTime windowEnd   = System.now().addHours(2);
        DateTime satTime     = System.now();

        Deployment_Window__c dw =
            ChangeLogTestDataFactory.insertDeploymentWindow(windowStart, windowEnd, 'Active');

        ChangeLogMetadataService.DeploymentWindowSchema dwSchema =
            ChangeLogTestDataFactory.makeDwSchema();

        List<SObject> dwList = [
            SELECT Id, Start_Date_Time__c, End_Date_Time__c, Status__c
            FROM Deployment_Window__c WHERE Id = :dw.Id
        ];

        SObject satRec = makeSat(null, satTime);

        Test.startTest();
        ChangeLogComplianceService svc = new ChangeLogComplianceService();
        Map<Id, ChangeLogComplianceService.ComplianceResult> results =
            svc.evaluate(new List<SObject>{ satRec }, dwList, dwSchema);
        Test.stopTest();

        // SAT record won't have a stable Id in simulate mode; check by iteration
        System.assert(!results.isEmpty(), 'Results should not be empty');
        for (ChangeLogComplianceService.ComplianceResult cr : results.values()) {
            System.assertEquals(ChangeLogConstants.COMPLIANT, cr.label,
                'Record inside window should be compliant');
            System.assertEquals(dw.Id, cr.windowId, 'Window Id should be populated');
        }
    }

    // ── evaluate() — non-compliant record ─────────────────────────────────────
    @IsTest
    static void testEvaluate_recordOutsideWindow_isNonCompliant() {
        DateTime windowStart = System.now().addDays(-10);
        DateTime windowEnd   = System.now().addDays(-9);
        DateTime satTime     = System.now();

        Deployment_Window__c dw =
            ChangeLogTestDataFactory.insertDeploymentWindow(windowStart, windowEnd, 'Active');

        ChangeLogMetadataService.DeploymentWindowSchema dwSchema =
            ChangeLogTestDataFactory.makeDwSchema();

        List<SObject> dwList = [
            SELECT Id, Start_Date_Time__c, End_Date_Time__c, Status__c
            FROM Deployment_Window__c WHERE Id = :dw.Id
        ];

        SObject satRec = makeSat(null, satTime);

        Test.startTest();
        ChangeLogComplianceService svc = new ChangeLogComplianceService();
        Map<Id, ChangeLogComplianceService.ComplianceResult> results =
            svc.evaluate(new List<SObject>{ satRec }, dwList, dwSchema);
        Test.stopTest();

        for (ChangeLogComplianceService.ComplianceResult cr : results.values()) {
            System.assertEquals(ChangeLogConstants.NON_COMPLIANT, cr.label,
                'Record outside all windows should be non-compliant');
            System.assertEquals(null, cr.windowId);
        }
    }

    // ── evaluate() — no active windows ───────────────────────────────────────
    @IsTest
    static void testEvaluate_noWindows_allNonCompliant() {
        SObject satRec = makeSat(null, System.now());
        ChangeLogMetadataService.DeploymentWindowSchema dwSchema =
            ChangeLogTestDataFactory.makeDwSchema();

        ChangeLogComplianceService svc = new ChangeLogComplianceService();
        Map<Id, ChangeLogComplianceService.ComplianceResult> results =
            svc.evaluate(new List<SObject>{ satRec }, new List<SObject>(), dwSchema);

        for (ChangeLogComplianceService.ComplianceResult cr : results.values()) {
            System.assertEquals(ChangeLogConstants.NON_COMPLIANT, cr.label);
        }
    }

    // ── evaluate() — null/empty inputs ────────────────────────────────────────
    @IsTest
    static void testEvaluate_nullSatRecords_returnsEmptyMap() {
        ChangeLogComplianceService svc = new ChangeLogComplianceService();
        Map<Id, ChangeLogComplianceService.ComplianceResult> results =
            svc.evaluate(null, new List<SObject>(), ChangeLogTestDataFactory.makeDwSchema());
        System.assert(results.isEmpty());
    }

    @IsTest
    static void testEvaluate_nullWindowList_resultsNonCompliant() {
        SObject satRec = makeSat(null, System.now());
        ChangeLogComplianceService svc = new ChangeLogComplianceService();
        Map<Id, ChangeLogComplianceService.ComplianceResult> results =
            svc.evaluate(new List<SObject>{ satRec }, null,
                ChangeLogTestDataFactory.makeDwSchema());

        for (ChangeLogComplianceService.ComplianceResult cr : results.values()) {
            System.assertEquals(ChangeLogConstants.NON_COMPLIANT, cr.label);
        }
    }

    // ── evaluate() — null dates on window ─────────────────────────────────────
    @IsTest
    static void testEvaluate_windowWithNullDates_skipsWindow() {
        Deployment_Window__c dw = new Deployment_Window__c(
            Start_Date_Time__c = null,
            End_Date_Time__c   = null,
            Status__c          = 'Active'
        );
        insert dw;

        List<SObject> dwList = [
            SELECT Id, Start_Date_Time__c, End_Date_Time__c, Status__c
            FROM Deployment_Window__c WHERE Id = :dw.Id
        ];

        SObject satRec = makeSat(null, System.now());
        ChangeLogComplianceService svc = new ChangeLogComplianceService();
        Map<Id, ChangeLogComplianceService.ComplianceResult> results =
            svc.evaluate(new List<SObject>{ satRec }, dwList,
                ChangeLogTestDataFactory.makeDwSchema());

        for (ChangeLogComplianceService.ComplianceResult cr : results.values()) {
            System.assertEquals(ChangeLogConstants.NON_COMPLIANT, cr.label,
                'Window with null dates should be skipped');
        }
    }

    // ── evaluate() — multiple windows, picks first match ─────────────────────
    @IsTest
    static void testEvaluate_multipleWindows_firstMatchWins() {
        DateTime satTime = System.now();
        Deployment_Window__c dw1 = ChangeLogTestDataFactory.insertDeploymentWindow(
            satTime.addHours(-1), satTime.addHours(1), 'Active');
        Deployment_Window__c dw2 = ChangeLogTestDataFactory.insertDeploymentWindow(
            satTime.addHours(-2), satTime.addHours(2), 'Active');

        List<SObject> dwList = [
            SELECT Id, Start_Date_Time__c, End_Date_Time__c, Status__c
            FROM Deployment_Window__c WHERE Id IN (:dw1.Id, :dw2.Id)
            ORDER BY Start_Date_Time__c ASC
        ];

        SObject satRec = makeSat(null, satTime);
        ChangeLogComplianceService svc = new ChangeLogComplianceService();
        Map<Id, ChangeLogComplianceService.ComplianceResult> results =
            svc.evaluate(new List<SObject>{ satRec }, dwList,
                ChangeLogTestDataFactory.makeDwSchema());

        for (ChangeLogComplianceService.ComplianceResult cr : results.values()) {
            System.assertEquals(ChangeLogConstants.COMPLIANT, cr.label);
            System.assertNotEquals(null, cr.windowId);
        }
    }
}