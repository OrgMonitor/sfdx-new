@IsTest
private class ChangeLogReviewControllerTest {
    @TestSetup
    static void setup() {
        insert new List<Change_Log__c>{
            row(false, 'CRITICAL', 'compliant'), row(true, 'CRITICAL', 'critical'),
            row(true, 'HIGH', 'high'), row(true, 'MEDIUM', 'medium'), row(true, 'LOW', 'low')
        };
    }

    @IsTest static void initializesLifecycleFromCompliance() {
        Map<String, Change_Log__c> rows = byKey();
        System.assertEquals('Closed', rows.get('compliant').Lifecycle_Status__c);
        System.assertEquals('Authorised', rows.get('compliant').Review_Outcome__c);
        for (String key : new List<String>{ 'critical', 'high', 'medium', 'low' }) {
            System.assertEquals('Review', rows.get(key).Lifecycle_Status__c);
            System.assertEquals(null, rows.get(key).Review_Outcome__c);
        }
    }

    @IsTest static void supportsDecisionsReopenAndBulk() {
        ChangeLogReviewController.bypassPermission = true;
        Map<String, Change_Log__c> rows = byKey();
        Test.startTest();
        ChangeLogReviewController.ReviewResult authorised = ChangeLogReviewController.applyAction(
            new List<Id>{ rows.get('critical').Id, rows.get('high').Id }, 'AUTHORISE');
        ChangeLogReviewController.ReviewResult unauthorised = ChangeLogReviewController.applyAction(
            new List<Id>{ rows.get('medium').Id }, 'UNAUTHORISE');
        ChangeLogReviewController.ReviewResult notReviewed = ChangeLogReviewController.applyAction(
            new List<Id>{ rows.get('low').Id }, 'CLOSE_WITHOUT_REVIEW');
        ChangeLogReviewController.applyAction(new List<Id>{ rows.get('medium').Id }, 'REOPEN');
        Test.stopTest();
        System.assertEquals(2, authorised.successCount);
        System.assertEquals(1, unauthorised.successCount);
        System.assertEquals(1, notReviewed.successCount);
        rows = byKey();
        System.assertEquals('Authorised', rows.get('critical').Review_Outcome__c);
        System.assertEquals('Review', rows.get('medium').Lifecycle_Status__c);
        System.assertEquals(null, rows.get('medium').Review_Outcome__c);
        System.assertEquals('Not Reviewed', rows.get('low').Review_Outcome__c);
    }

    @IsTest static void rejectsMixedCloseWithoutReviewSelection() {
        ChangeLogReviewController.bypassPermission = true;
        Map<String, Change_Log__c> rows = byKey();
        try {
            ChangeLogReviewController.applyAction(
                new List<Id>{ rows.get('critical').Id, rows.get('low').Id }, 'CLOSE_WITHOUT_REVIEW');
            System.assert(false, 'Expected the mixed selection to be rejected.');
        } catch (AuraHandledException expected) {
            System.assertNotEquals(null, expected);
        }
        System.assertEquals('Review', [SELECT Lifecycle_Status__c FROM Change_Log__c WHERE Id = :rows.get('low').Id].Lifecycle_Status__c);
    }

    @IsTest static void validationRulesProtectDirectUpdates() {
        Map<String, Change_Log__c> rows = byKey();
        Change_Log__c critical = rows.get('critical');
        critical.Lifecycle_Status__c = 'Closed'; critical.Review_Outcome__c = 'Not Reviewed';
        Database.SaveResult criticalResult = Database.update(critical, false);
        System.assertEquals(false, criticalResult.isSuccess());
        Change_Log__c medium = rows.get('medium');
        medium.Review_Outcome__c = 'Authorised';
        Database.SaveResult openResult = Database.update(medium, false);
        System.assertEquals(false, openResult.isSuccess());
    }

    @IsTest static void visualforceBulkExtensionAppliesSelection() {
        ChangeLogReviewController.bypassPermission = true;
        Change_Log__c low = byKey().get('low');
        Test.setCurrentPage(Page.ChangeLogBulkReview);
        ApexPages.StandardSetController standardController = new ApexPages.StandardSetController(
            [SELECT Id FROM Change_Log__c WHERE Id = :low.Id]);
        standardController.setSelected(new List<Change_Log__c>{ low });
        ChangeLogBulkReviewExtension extension = new ChangeLogBulkReviewExtension(standardController);
        System.assertEquals(1, extension.selectedIds.size());
        Test.startTest();
        extension.apply();
        PageReference destination = extension.cancel();
        Test.stopTest();
        System.assertEquals(1, extension.result.successCount);
        System.assert(destination.getUrl().contains('/lightning/o/Change_Log__c/list'));
    }

    private static Change_Log__c row(Boolean nonCompliant, String severity, String key) {
        return new Change_Log__c(Non_Compliant__c = nonCompliant, Severity__c = severity,
            External_Id__c = key, Change_Summary__c = key);
    }
    private static Map<String, Change_Log__c> byKey() {
        Map<String, Change_Log__c> result = new Map<String, Change_Log__c>();
        for (Change_Log__c row : [SELECT Id, External_Id__c, Non_Compliant__c, Severity__c,
                Lifecycle_Status__c, Review_Outcome__c FROM Change_Log__c]) result.put(row.External_Id__c, row);
        return result;
    }
}