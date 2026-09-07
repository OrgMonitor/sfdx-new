/**
 * ChangeLogEmailScheduler
 * Runs once a day at a specified time.
 * Queries non-compliant Change_Log__c records that haven't
 * had a violation email sent yet, and sends notifications.
 * Runs the job right now — no waiting for cron
 * S new ChangeLogEmailScheduler().execute(null);

 */
public class ChangeLogEmailScheduler implements Schedulable {

    public void execute(SchedulableContext ctx) {

        // Step 1: Query non-compliant Change_Log__c records
        // where the email hasn't been sent yet
        List<Change_Log__c> confirmedViolations = [
            SELECT Id, Name, External_Id__c, Section__c, Action__c,
                   Log_Created_Date__c, Changed_By_User__c,
                   IP_Address__c, User_Location_City__c,
                   User_Location_State__c, User_Location_Country__c,
                   Non_Compliant__c, Email_Sent__c, Related_Case__c, Severity__c
            FROM Change_Log__c
            WHERE Non_Compliant__c = true
              AND Email_Sent__c = false AND Changed_By_User__r.name != null
            LIMIT 12
        ];

        if (confirmedViolations.isEmpty()) {
            System.debug('No pending violation emails to send.');
            return;
        }

        // Step 2: Re-query the related SetupAuditTrail rows
        // (needed for CreatedBy.Email, Manager info, etc.)
        Set<String> externalIds = new Set<String>();
        for (Change_Log__c log : confirmedViolations) {
            externalIds.add(log.External_Id__c);
        }

        List<SetupAuditTrail> auditRows = [
            SELECT Id, CreatedDate, CreatedById,
                   CreatedBy.Name, CreatedBy.Email,
                   CreatedBy.ManagerId,
                   CreatedBy.Manager.Email, CreatedBy.Manager.Name,
                   Action, Section, Display
            FROM SetupAuditTrail
            WHERE Id IN :externalIds
        ];

        // Step 3: Get the Custom Metadata config
        List<Change_Log_Config__mdt> configList = [
            SELECT Case_Queue_Id__c, Additional_Email_CC__c,
                   Email_Template_Name__c
            FROM Change_Log_Config__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        Change_Log_Config__mdt config = configList.isEmpty()
                                         ? null : configList[0];

        // Step 4: Call the existing email service method
        ChangeLogEmailService.sendViolationEmails(confirmedViolations, auditRows, config);
        
        // Calculate and persist (Org Score)
        OrgSecurityScoreService.ScoreResult result = OrgSecurityScoreService.calculateOrgScore(30);
        
        ChangeLogRuntime__c rt = ChangeLogRuntime__c.getOrgDefaults();
        if (rt == null) rt = new ChangeLogRuntime__c();
        
        rt.Org_Health_Score__c    = result.orgScore;
        rt.Score_Band__c          = result.band;
        rt.Score_Calculated_At__c = result.calculatedAt;
        rt.Compliance_Rate__c     = result.complianceRate;
        /*rt.Score_Breakdown_JSON__c = JSON.serialize(
            new Map<String, Object>{
                'bySection'       => result.scoreBySection,
                'byUser'          => result.scoreByUser,
                'totalRecords'    => result.totalRecords,
                'compliantCount'  => result.compliantCount,
                'nonCompliantCount' => result.nonCompliantCount   Create Score_Status__c as a Formula (Text) instead of picklist so it auto-derives:

            }
        );*/
        System.debug('rt:::' + rt );
        upsert rt;

        System.debug('Processed ' + confirmedViolations.size()
                     + ' violation email(s).');
    }
}