/**
 * Replacement Org Monitor collection job. It uses a bounded source window,
 * advances the checkpoint only after lossless persistence, and emits notifications
 * only for records created by this run.
 */
public without sharing class OrgMonitorChangeDetectionBatch
        implements Database.Batchable<SObject>, Database.Stateful {
    private OrgMonitorChangeRunConfig config;
    private String runCorrelationId;
    private Boolean persistenceSuccessful = true;
    private Integer createdCount = 0;
    private List<String> diagnostics = new List<String>();
    private String failurePhase;

    public Database.QueryLocator start(Database.BatchableContext context) {
        try {
            preventOverlap(context.getJobId());
            config = OrgMonitorChangeRunConfig.load(System.now());
            // Include the batch job ID so two legitimate runs sharing the same second can
            // never select each other's records when the digest is reconstructed in finish.
            runCorrelationId = 'OM-' + config.runCutoff.formatGMT('yyyyMMdd-HHmmssSSS')
                + '-' + String.valueOf(context.getJobId());
            Datetime lowerBoundary = config.lowerBoundary;
            Datetime runCutoff = config.runCutoff;
            return Database.getQueryLocator([
                SELECT Id, CreatedDate, CreatedById, CreatedBy.Name,
                       Action, Section, Display, DelegateUser
                FROM SetupAuditTrail
                WHERE CreatedDate > :lowerBoundary
                  AND CreatedDate <= :runCutoff
                  AND CreatedById != null
                  AND CreatedBy.Name != 'Automated Process'
                ORDER BY CreatedDate ASC, Id ASC
            ]);
        } catch (Exception startupError) {
            recordFailure('Configuration and startup validation', startupError.getMessage());
            return Database.getQueryLocator([SELECT Id FROM SetupAuditTrail WHERE Id = null]);
        }
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        try {
            OrgMonitorChangeProcessor.Outcome outcome =
                new OrgMonitorChangeProcessor().process(scope, config, runCorrelationId);
            createdCount += outcome.createdCount;
            if (!outcome.successful) {
                persistenceSuccessful = false;
                if (String.isBlank(failurePhase)) failurePhase = 'Change processing and persistence';
            }
            for (String diagnostic : outcome.diagnostics) {
                if (diagnostics.size() < 20) diagnostics.add(diagnostic);
            }
        } catch (Exception error) {
            recordFailure('Change processing and persistence', error.getMessage());
        }
    }

    public void finish(Database.BatchableContext context) {
        if (!persistenceSuccessful) {
            System.debug(LoggingLevel.ERROR, '[OrgMonitor change detection] Watermark not advanced. '
                + String.join(diagnostics, ' | '));
            notifyAdministrator(false);
            return;
        }
        ChangeLogRuntime__c settings = ChangeLogRuntime__c.getOrgDefaults();
        if (settings == null) {
            recordFailure('Watermark update', 'Org Monitor App Setup configuration is missing.');
            notifyAdministrator(false);
            return;
        }
        try {
            settings.Last_Run_Timestamp__c = config.runCutoff;
            update settings;
        } catch (Exception watermarkError) {
            recordFailure('Watermark update', watermarkError.getMessage());
            notifyAdministrator(false);
            return;
        }
        if (createdCount > 0) {
            try {
                OrgMonitorChangeDigestService.dispatch(
                    runCorrelationId, config.lowerBoundary, config.runCutoff,
                    config.orgTimeZoneSidKey);
            } catch (Exception notificationError) {
                // Collection is already durable. Notification retries and delivery
                // state belong to the existing provider-neutral notification layer.
                System.debug(LoggingLevel.ERROR,
                    '[OrgMonitor change detection] Notification preparation failed: '
                    + sanitize(notificationError.getMessage()));
                failurePhase = 'Notification preparation';
                diagnostics.clear();
                diagnostics.add(sanitize(notificationError.getMessage()));
                notifyAdministrator(true);
            }
        }
    }

    private void preventOverlap(Id currentJobId) {
        Integer overlapping = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'OrgMonitorChangeDetectionBatch'
              AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
              AND Id != :currentJobId
        ];
        if (overlapping > 0) throw new OverlappingRunException('Another Org Monitor change-detection run is active.');
    }
    private String sanitize(String value) {
        if (String.isBlank(value)) return 'Unexpected processing failure.';
        return value.replaceAll('[\r\n\t]+', ' ').left(Math.min(value.length(), 500));
    }
    private void recordFailure(String phase, String detail) {
        persistenceSuccessful = false;
        if (String.isBlank(failurePhase)) failurePhase = phase;
        if (diagnostics.size() < 20) diagnostics.add(sanitize(detail));
    }
    private void notifyAdministrator(Boolean watermarkAdvanced) {
        OrgMonitorBatchErrorNotificationService.send(failurePhase,
            diagnostics.isEmpty() ? null : String.join(diagnostics, ' | '),
            runCorrelationId, watermarkAdvanced);
    }
    public class OverlappingRunException extends Exception { }
}