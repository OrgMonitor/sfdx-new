/** Schedulable wrapper for the replacement Org Monitor collector. */
public without sharing class OrgMonitorChangeDetectionScheduler implements Schedulable {
    public static final String JOB_NAME_PREFIX = 'OrgMonitorChangeDetection_5Min_';

    /**
     * Replaces any existing schedule for this producer with one five-minute job.
     * This is safe to call repeatedly when App Setup is saved.
     */
    public static List<Id> scheduleEveryFiveMinutes() {
        String jobPattern = JOB_NAME_PREFIX + '%';
        for (CronTrigger scheduledJob : [
            SELECT Id
            FROM CronTrigger
            WHERE CronJobDetail.Name LIKE :jobPattern
              AND State NOT IN ('DELETED', 'COMPLETE', 'ERROR')
        ]) {
            System.abortJob(scheduledJob.Id);
        }
        // Scheduled Apex requires an integer minute; step syntax such as 0/5 is
        // rejected. Twelve deterministic schedules provide a true five-minute cadence.
        List<Id> scheduledIds = new List<Id>();
        for (Integer minute = 0; minute < 60; minute += 5) {
            scheduledIds.add(System.schedule(JOB_NAME_PREFIX + String.valueOf(minute),
                '0 ' + minute + ' * * * ?', new OrgMonitorChangeDetectionScheduler()));
        }
        return scheduledIds;
    }

    public void execute(SchedulableContext context) {
        Integer active = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'OrgMonitorChangeDetectionBatch'
              AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
        ];
        if (active == 0) Database.executeBatch(new OrgMonitorChangeDetectionBatch(), 200);
    }
}