public class ChangeLogLifecycleHandler {
    public static void beforeSave(List<Change_Log__c> rows, Map<Id, Change_Log__c> oldMap) {
        for (Change_Log__c row : rows) {
            Change_Log__c oldRow = oldMap == null ? null : oldMap.get(row.Id);
            Boolean isInsert = oldRow == null;
            if (isInsert && row.RecordTypeId == null) {
                Schema.RecordTypeInfo lifecycleType = Schema.SObjectType.Change_Log__c
                    .getRecordTypeInfosByDeveloperName().get('Review_Lifecycle');
                if (lifecycleType != null) row.RecordTypeId = lifecycleType.getRecordTypeId();
            }
            Boolean complianceChanged = !isInsert && row.Non_Compliant__c != oldRow.Non_Compliant__c;
            if (isInsert || complianceChanged) {
                if (row.Non_Compliant__c == true) {
                    row.Lifecycle_Status__c = 'Review';
                    row.Review_Outcome__c = null;
                } else {
                    row.Lifecycle_Status__c = 'Closed';
                    row.Review_Outcome__c = 'Authorised';
                }
            }
        }
    }
}