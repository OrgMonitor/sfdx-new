public with sharing class ChangeLogReviewController {
    public static final String AUTHORISE = 'AUTHORISE';
    public static final String UNAUTHORISE = 'UNAUTHORISE';
    public static final String CLOSE_WITHOUT_REVIEW = 'CLOSE_WITHOUT_REVIEW';
    public static final String REOPEN = 'REOPEN';
    private static final Integer MAX_SELECTION = 2000;
    @TestVisible private static Boolean bypassPermission = false;

    public class ReviewResult {
        @AuraEnabled public Integer selectedCount { get; set; }
        @AuraEnabled public Integer successCount { get; set; }
        @AuraEnabled public Integer failureCount { get; set; }
        @AuraEnabled public List<String> errors { get; set; }
        public ReviewResult() {
            selectedCount = 0; successCount = 0; failureCount = 0;
            errors = new List<String>();
        }
    }

    @AuraEnabled
    public static ReviewResult applyAction(List<Id> recordIds, String actionName) {
        requireReviewer();
        String action = normalizeAction(actionName);
        Set<Id> uniqueIds = recordIds == null ? new Set<Id>() : new Set<Id>(recordIds);
        if (uniqueIds.isEmpty()) throw friendly('Select at least one Change Log.');
        if (uniqueIds.size() > MAX_SELECTION) throw friendly('Select no more than 2,000 Change Logs at a time.');
        requireUpdateAccess();

        List<Change_Log__c> rows = [
            SELECT Id, Name, Non_Compliant__c, Severity__c, Lifecycle_Status__c, Review_Outcome__c
            FROM Change_Log__c WHERE Id IN :uniqueIds WITH USER_MODE ORDER BY Id
        ];
        ReviewResult result = new ReviewResult();
        result.selectedCount = uniqueIds.size();
        if (rows.size() != uniqueIds.size()) {
            throw friendly('One or more selected Change Logs were not found or are not accessible.');
        }
        if (action == CLOSE_WITHOUT_REVIEW) {
            for (Change_Log__c row : rows) {
                if (!isEligible(row, action)) {
                    throw friendly('Close Without Review is allowed only when every selected change is a non-compliant Medium or Low item in Review.');
                }
            }
        }

        List<Change_Log__c> updates = new List<Change_Log__c>();
        for (Change_Log__c row : rows) {
            if (!isEligible(row, action)) {
                result.failureCount++;
                result.errors.add(row.Name + ': this action is not available for the current review state.');
                continue;
            }
            Change_Log__c change = new Change_Log__c(Id = row.Id);
            if (action == REOPEN) {
                change.Lifecycle_Status__c = 'Review';
                change.Review_Outcome__c = null;
            } else {
                change.Lifecycle_Status__c = 'Closed';
                change.Review_Outcome__c = action == AUTHORISE ? 'Authorised'
                    : action == UNAUTHORISE ? 'Unauthorised' : 'Not Reviewed';
            }
            updates.add(change);
        }
        if (!updates.isEmpty()) {
            Database.SaveResult[] saves = Database.update(updates, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < saves.size(); i++) {
                if (saves[i].isSuccess()) result.successCount++;
                else {
                    result.failureCount++;
                    for (Database.Error error : saves[i].getErrors()) {
                        result.errors.add(String.valueOf(updates[i].Id) + ': ' + error.getMessage());
                    }
                }
            }
        }
        return result;
    }

    private static Boolean isEligible(Change_Log__c row, String action) {
        if (row.Non_Compliant__c != true) return false;
        if (action == REOPEN) return row.Lifecycle_Status__c == 'Closed';
        if (row.Lifecycle_Status__c != 'Review') return false;
        if (action == CLOSE_WITHOUT_REVIEW) {
            return row.Severity__c == 'MEDIUM' || row.Severity__c == 'LOW';
        }
        return action == AUTHORISE || action == UNAUTHORISE;
    }

    private static String normalizeAction(String actionName) {
        String value = String.isBlank(actionName) ? '' : actionName.trim().toUpperCase();
        if (!new Set<String>{ AUTHORISE, UNAUTHORISE, CLOSE_WITHOUT_REVIEW, REOPEN }.contains(value)) {
            throw friendly('Unknown review action.');
        }
        return value;
    }

    private static void requireReviewer() {
        if (!bypassPermission && !FeatureManagement.checkPermission('Review_Change_Logs')) {
            throw friendly('You do not have permission to review Change Logs.');
        }
    }

    private static void requireUpdateAccess() {
        if (!Schema.sObjectType.Change_Log__c.isUpdateable()
            || !Schema.sObjectType.Change_Log__c.fields.Lifecycle_Status__c.isUpdateable()
            || !Schema.sObjectType.Change_Log__c.fields.Review_Outcome__c.isUpdateable()) {
            throw friendly('You do not have access to update Change Log review fields.');
        }
    }

    private static AuraHandledException friendly(String message) {
        return new AuraHandledException(message);
    }
}