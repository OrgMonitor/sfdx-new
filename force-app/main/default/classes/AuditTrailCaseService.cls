/**
 * AuditTrailCaseService
 * Creates Cases for non-compliant Audit Trail violations and assigns to queue.
 */
public class AuditTrailCaseService {

    public static void createCasesForViolations(
        List<Change_Log__c> violations,
        List<SetupAuditTrail> auditRows
    ) {
        // Build lookup: External_Id → SetupAuditTrail row
        Map<String, SetupAuditTrail> rowMap = new Map<String, SetupAuditTrail>();
        for (SetupAuditTrail r : auditRows) rowMap.put(r.Id, r);
		
        // Get queue Id from Custom Setting
        ChangeLogRuntime__c config  = ChangeLogRuntime__c.getOrgDefaults();
        String queueId = config?.Case_Queue_Id__c;

        List<Case>              casesToInsert   = new List<Case>();
        List<Change_Log__c>    logsToUpdate    = new List<Change_Log__c>();

        // Derive priority from Component severity (stored on the log via lookup)
        Map<String, String> severityToPriority = new Map<String, String>{
            'Critical' => 'High',
            'High'     => 'High',
            'Medium'   => 'Medium',
            'Low'      => 'Low'
        };

        for (Change_Log__c log : violations) {
            SetupAuditTrail row = rowMap.get(log.External_Id__c);
            if (row == null) continue;

            Case c = new Case(
                Subject     = '[Non-Compliant] ' + log.Section__c
                              + ' change by ' + row.CreatedBy.Name,
                Description = 'Audit Trail Section: ' + log.Section__c
                              + '\nAction: ' + log.Action__c
                              + '\nChanged By: ' + row.CreatedBy.Name
                              + '\nDate/Time: ' + log.Log_Created_Date__c,
                Origin      = 'Audit Trail Monitor',
                Status      = 'New',
                Priority    = 'High',  // override with component severity if needed
                OwnerId     = queueId,
                // Custom lookup field on Case pointing to Change_Log__c
                Change_Log__c = log.Id
            );
            casesToInsert.add(c);
            logsToUpdate.add(log); // track order to back-link case
        }
System.debug('casesToInsert:::' + casesToInsert);
        if (casesToInsert.isEmpty()) return;

        Database.SaveResult[] results = Database.insert(casesToInsert, false);
System.debug('results:::' + results);
        // Back-link Case Id onto the Change_Log__c record
        List<Change_Log__c> backLinks = new List<Change_Log__c>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                backLinks.add(new Change_Log__c(
                    Id      = logsToUpdate[i].Id,
                    Related_Case__c = results[i].getId()
                ));
            }
        }
        if (!backLinks.isEmpty()) update backLinks;
    }
}