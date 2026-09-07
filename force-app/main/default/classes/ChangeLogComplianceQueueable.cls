/**
 * ChangeLogComplianceQueueable
 * Queries SetupAuditTrail, evaluates compliance, creates Change_Log__c records,
 * triggers Case creation and email notification for violations.
 */
public class ChangeLogComplianceQueueable implements Queueable, Database.AllowsCallouts {

    public void execute(QueueableContext ctx) {
            try{
            // ── Step 1: Read high-watermark from Custom Metadata ──────────────────
            // Step 1: Read config safely — handle null if no record found
            List<Change_Log_Config__mdt> configList = [
                SELECT Case_Queue_Id__c, Additional_Email_CC__c,
                       Email_Template_Name__c
                FROM Change_Log_Config__mdt
                WHERE DeveloperName = 'Default'
                LIMIT 1
            ];
            Change_Log_Config__mdt config = configList.isEmpty() ? null : configList[0];
            
            // Step 2: Read high-watermark from Custom Setting (writable at runtime)
            ChangeLogRuntime__c changeLogSetup = ChangeLogRuntime__c.getOrgDefaults();
            Datetime lastRun = Datetime.now().addMinutes(-35);
            String deploymentUserId;
            if (changeLogSetup != null){
                if(changeLogSetup.Last_Run_Timestamp__c != null){
                    lastRun = changeLogSetup.Last_Run_Timestamp__c;
                }
                deploymentUserId = changeLogSetup.Deployment_User_Id__c;
            }
            
            Datetime runStart = Datetime.now();
           
            // ── Step 2: Query SetupAuditTrail for new rows ────────────────────────-----
            List<SetupAuditTrail> auditRows = [
                SELECT Id, CreatedDate, CreatedById, CreatedBy.Name,
                       CreatedBy.Email, CreatedBy.ManagerId,
                       CreatedBy.Manager.Email, CreatedBy.Manager.Name,
                       Action, Section, Display,
                       DelegateUser
                FROM SetupAuditTrail
                WHERE CreatedDate > :lastRun AND (NOT CreatedBy.Name IN ('Automated Process', null))
                ORDER BY CreatedDate ASC
            ];
    
            if (auditRows.isEmpty()) {
                updateHighWatermark(runStart);
                return;
            }
            
            // Get the login history of audit trail user
            Set<Id> createdByIds = new Set<Id>();
            for(SetupAuditTrail ar: auditRows){
                createdByIds.add(ar.CreatedById);            
            }
            // Considerring the latest login history record only
            Map<Id, LoginHistory> loginHistoryMap = new Map<Id, LoginHistory>();
         
            for(LoginHistory lh: [SELECT id, UserId, LoginTime, SourceIp, ForwardedForIp, LoginGeo.Country, LoginGeo.PostalCode ,LoginGeo.City,LoginGeo.Subdivision 
                                    FROM LoginHistory WHERE UserId = :createdByIds Order By LoginTime  DESC LIMIT 1]){
                loginHistoryMap.put(lh.UserId, lh);            
            }
    
            // ── Step 3: Load Approved Change Windows with their Components ──────────
            /*List<Deployment_Window__c> activeWindows = [
                SELECT Id, Start_Date_Time__c, End_Date_Time__c,
                    (SELECT Id, Audit_Trail_Section__c, Severity__c, Is_Active__c
                     FROM Tracked_Components__r
                     WHERE Is_Active__c = TRUE)
                FROM Deployment_Window__c
                WHERE Status__c = 'Approved'
                  AND Start_Date_Time__c <= :runStart
                  AND End_Date_Time__c   >= :lastRun
            ];*/
                List<Deployment_Window__c> activeWindows = [
                SELECT Id, Start_Date_Time__c, End_Date_Time__c
                FROM Deployment_Window__c
                WHERE Status__c = 'Active'
                  AND Start_Date_Time__c <= :runStart
                  AND End_Date_Time__c   >= :lastRun
            	];
           		System.debug('runStart:::' + runStart);
                System.debug('lastRun:::' + lastRun);
            // ── Step 4: Process each audit row ───────────────────────────────────
            List<Change_Log__c>  toUpsert      = new List<Change_Log__c>();
            List<Change_Log__c>  nonCompliant  = new List<Change_Log__c>();
    		
            for (SetupAuditTrail row : auditRows) {
                 if(!loginHistoryMap.containsKey(row.CreatedById)) {
                     continue;
                 }
                
                // Get full match including score
                AuditTrailSeverityService.MatchResult match = AuditTrailSeverityService.getMatch(row.Section, row.Action);
            
                // Non-compliant actions get penalised score
                Integer finalScore = match.actionScore;
                /*if (!result.isCompliant) {
                    // Penalise by 40% for happening outside a window
                    finalScore = (Integer)(match.actionScore * 0.6).round();
                }*/
            
                Decimal weightedScore = finalScore * (match.scoreWeight ?? 1.0);
            	System.debug('loginHistoryMap:::' + loginHistoryMap);
                LoginHistory loginHistoryRecord = loginHistoryMap.get(row.CreatedById);
                System.debug('deploymentUserId::' + deploymentUserId);
                Change_Log__c log = new Change_Log__c(
                    External_Id__c      = row.Id,           // External ID field to prevent duplicates
                    Log_Created_Date__c = row.CreatedDate,
                    Changed_By_User__c  = row.CreatedById,
                    Section__c          = row.Section,
                    Action__c           = row.Action,
                    Details__c           = row.Display,
                    Raw_Audit_Entry__c  = JSON.serialize(row),
                    Deployment_User_Log__c = deploymentUserId.contains(row.CreatedById),
                    Non_Compliant__c    = false,
                    Email_Sent__c       = false,
                    Severity__c = AuditTrailSeverityService.getSeverity(row.Action),
                    Source_IP__c = loginHistoryRecord.SourceIp, 
                    Forwarded_For_IP__c = loginHistoryRecord.ForwardedForIp,
                    User_Location_City__c  = loginHistoryRecord.LoginGeo.City,  
                    User_Location_Country__c  = loginHistoryRecord.LoginGeo.Country ,
                    User_Location_Postal_Code__c  = loginHistoryRecord.LoginGeo.PostalCode,
                    User_Location_State__c  = loginHistoryRecord.LoginGeo.Subdivision,
                    Weighted_Score__c    = weightedScore    // for aggregation
                );
    
                // ── Compliance Check ─────────────────────────────────────────────
                ComplianceResult result = evaluateCompliance(row, activeWindows);
            System.debug('result:::' + result);
                if (!result.isCompliant) {
                    finalScore = (Integer)(match.actionScore * 0.6).round();
                    log.Action_Score__c = finalScore;
                    log.Non_Compliant__c   = true;
                    log.Non_Compliant_Reason__c = result.nonCompliantReason;
                    log.Matched_Deployment_Window__c   = result.matchedWindowId;   // null if no window matched
                    log.Matched_Component__c       = result.matchedComponentId; // null if section not matched
                    nonCompliant.add(log);
                } else {
                    log.Matched_Deployment_Window__c   = result.matchedWindowId;
                    log.Matched_Component__c       = result.matchedComponentId;
                }
                
                toUpsert.add(log);
            }
            // ── Step 5: Upsert Change_Log__c records ────────────────────────────
            List<Database.UpsertResult> upsertResults =
                Database.upsert(toUpsert, Change_Log__c.External_Id__c, false);
    
            // Map upserted records back to non-compliant list using External_Id
            List<Change_Log__c> confirmedViolations = new List<Change_Log__c>();
            Map<String, Id> extIdToSfId = new Map<String, Id>();
    
            for (Change_Log__c rec : [
                SELECT Id, External_Id__c FROM Change_Log__c
                WHERE External_Id__c IN :getExternalIds(nonCompliant)
            ]) {
                extIdToSfId.put(rec.External_Id__c, rec.Id);
            }
    
            for (Change_Log__c nc : nonCompliant) {
                if (extIdToSfId.containsKey(nc.External_Id__c)) {
                    nc.Id = extIdToSfId.get(nc.External_Id__c);
                    confirmedViolations.add(nc);
                }
            }
    
            // ── Step 6: Create Cases + Send Emails for violations ─────────────────
            if (!confirmedViolations.isEmpty()) {
                if(changeLogSetup.Create_Case_For_Non_Compliant__c){
                    AuditTrailCaseService.createCasesForViolations(confirmedViolations, auditRows);
                }
                ChangeLogEmailService.sendViolationEmails(confirmedViolations, auditRows, config);
            }
    
            // ── Step 7: Update high-watermark ─────────────────────────────────────
            updateHighWatermark(auditRows[auditRows.size() - 1].CreatedDate);
         } catch (Exception e) {
            AuditTrailLogger.logException(
                e,
                'AuditTrailComplianceQueueable',
                'execute',
                'Scheduled compliance check — processing SetupAuditTrail batch',
                null,
                'Critical'
            );
            // Re-throw or swallow depending on whether you want
            // the Queueable job itself marked as Failed
            throw e;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // COMPLIANCE EVALUATION
    // ─────────────────────────────────────────────────────────────────────────

    private ComplianceResult evaluateCompliance(SetupAuditTrail row,List<Deployment_Window__c> activeWindows) {
        ComplianceResult result = new ComplianceResult();

        for (Deployment_Window__c win : activeWindows) {

            // Check A: Is the change within this window's time range?
            Boolean withinWindow = (row.CreatedDate >= win.Start_Date_Time__c
                                 && row.CreatedDate <= win.End_Date_Time__c);
            System.debug('win.Start_Date_Time__c:::' + win.Start_Date_Time__c);
            System.debug('win.End_Date_Time__c:::' + win.End_Date_Time__c);
            System.debug('withinWindow:::' + withinWindow);
            
            if (withinWindow) {
                // Within a window -> Compliant
                result.isCompliant     = true;
                result.matchedWindowId = win.Id; // window matched but component didn't
                return result;
            }

            // Check B: Does the section match a tracked component in this window?
            /*for (Tracked_Component__c  comp : win.Tracked_Components__r) {
                if (comp.Audit_Trail_Section__c.equalsIgnoreCase(row.Section)) {
                    // Fully compliant — within window AND section is tracked
                    result.isCompliant        = true;
                    result.matchedWindowId    = win.Id;
                    result.matchedComponentId = comp.Id;
                    return result;
                }
            }*/
			
            
        }

        // No window matched at all → Non-Compliant
        result.isCompliant = false;
        result.nonCompliantReason = 'Changes made outside the approved change request';
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    private void updateHighWatermark(Datetime newTimestamp) {
        // Custom Metadata cannot be updated via DML in Apex directly.
        // Use a Custom Setting (hierarchy or list) for runtime write access.
        // Alternatively, use a platform cache or Named Credential workaround.
        // Below uses a List Custom Setting: AuditTrailRuntime__c
        ChangeLogRuntime__c runtime = ChangeLogRuntime__c.getOrgDefaults();
        if (runtime == null) runtime = new ChangeLogRuntime__c();
        runtime.Last_Run_Timestamp__c = newTimestamp;
        upsert runtime;
    }

    private Set<String> getExternalIds(List<Change_Log__c> records) {
        Set<String> ids = new Set<String>();
        for (Change_Log__c r : records) ids.add(r.External_Id__c);
        return ids;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INNER CLASS — Compliance Result wrapper
    // ─────────────────────────────────────────────────────────────────────────

    private class ComplianceResult {
        Boolean isCompliant     = false;
        Id      matchedWindowId = null;
        Id      matchedComponentId = null;
        String nonCompliantReason = '';
    }
    
}