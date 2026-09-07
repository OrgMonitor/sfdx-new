/**
 * GovernanceSetupController
 *
 * LWC controller for the Governance Setup Wizard.
 * Exposes user search, settings persistence, and batch scheduling.
 *
 * Security: every entry point requires the packaged Manage Org Monitor Setup
 * custom permission. User records are queried in user mode. Org-wide runtime
 * configuration, queue membership, and scheduler administration intentionally
 * run in system mode only after that explicit administrative authorization.
 */
public with sharing class GovernanceSetupController {

    @TestVisible
    private static OrgMonitorOrganizationContext organizationContext = new OrgMonitorOrganizationContext();

    // ── Inner DTO ─────────────────────────────────────────────────────────────

    public class UserResult {
        @AuraEnabled public String id;
        @AuraEnabled public String label;       // Full Name
        @AuraEnabled public String sublabel;    // Email

        public UserResult(String id, String name, String email) {
            this.id       = id;
            this.label    = name;
            this.sublabel = email;
        }
    }
    public class WizardState {
        @AuraEnabled public List<UserResult> deploymentUsers = new List<UserResult>();
        @AuraEnabled public Boolean enableApproval;
        @AuraEnabled public Boolean skipDeploymentWindowsForSandbox;
        @AuraEnabled public Boolean isSandbox;
        @AuraEnabled public List<UserResult> approvalUsers = new List<UserResult>();
        @AuraEnabled public Integer initialRunWindow;
        @AuraEnabled public String unusualHoursStart;
        @AuraEnabled public String unusualHoursEnd;
        @AuraEnabled public Integer lastSavedStage;
        @AuraEnabled public Boolean monitoringActive;
        @AuraEnabled public Boolean slackEnabled;
        @AuraEnabled public Boolean teamsEnabled;
        @AuraEnabled public String slackWorkspaceId; @AuraEnabled public String slackWorkspaceName;
        @AuraEnabled public String slackChannelId; @AuraEnabled public String slackChannelName;
        @AuraEnabled public Datetime slackLastTest; @AuraEnabled public Boolean slackPrivateChannels;
        @AuraEnabled public String teamsTenantId; @AuraEnabled public String teamsTeamId; @AuraEnabled public String teamsTeamName;
        @AuraEnabled public String teamsChannelId; @AuraEnabled public String teamsChannelName; @AuraEnabled public Datetime teamsLastTest;
        @AuraEnabled public String teamsIdentityId; @AuraEnabled public String teamsIdentityName;
        @AuraEnabled public CollaborationCredentialService.OAuthInfo slackCredential;
        @AuraEnabled public CollaborationCredentialService.OAuthInfo teamsCredential;
    }

    @AuraEnabled
    public static WizardState getWizardState() {
        OrgMonitorSetupSecurity.requireManageSetup();
        WizardState result = new WizardState();
        result.isSandbox = organizationContext.isSandbox();
        result.skipDeploymentWindowsForSandbox = false;
        ChangeLogRuntime__c setting = ChangeLogRuntime__c.getOrgDefaults();
        if (setting != null) {
            result.enableApproval = setting.Enable_Deployment_Window_Approval__c;
            result.skipDeploymentWindowsForSandbox = result.isSandbox && setting.Skip_Deployment_Windows_For_Sandbox__c;
            result.initialRunWindow = setting.Initial_Run_Window__c == null ? null : Integer.valueOf(setting.Initial_Run_Window__c);
            result.unusualHoursStart = setting.Unusual_Hours_Start__c;
            result.unusualHoursEnd = setting.Unusual_Hours_End__c;
            result.lastSavedStage = setting.Last_Saved_Stage__c == null ? 0 : Integer.valueOf(setting.Last_Saved_Stage__c);
            result.slackEnabled = setting.Slack_Notifications_Enabled__c; result.teamsEnabled = setting.Teams_Notifications_Enabled__c;
            result.slackWorkspaceId = setting.Slack_Workspace_Id__c; result.slackWorkspaceName = setting.Slack_Workspace_Name__c;
            result.slackChannelId = setting.Slack_Channel_Id__c; result.slackChannelName = setting.Slack_Channel_Name__c;
            result.slackLastTest = setting.Slack_Last_Test__c; result.slackPrivateChannels = setting.Slack_Private_Channels__c;
            result.teamsTenantId = setting.Teams_Tenant_Id__c; result.teamsTeamId = setting.Teams_Team_Id__c; result.teamsTeamName = setting.Teams_Team_Name__c;
            result.teamsChannelId = setting.Teams_Channel_Id__c; result.teamsChannelName = setting.Teams_Channel_Name__c; result.teamsLastTest = setting.Teams_Last_Test__c;
            result.teamsIdentityId = setting.Teams_Identity_Id__c; result.teamsIdentityName = setting.Teams_Identity_Name__c;
            Set<Id> deploymentIds = parseIds(setting.Deployment_User_Id__c);
            if (!deploymentIds.isEmpty()) for (User u : [SELECT Id, Name, Email FROM User WHERE Id IN :deploymentIds WITH USER_MODE]) result.deploymentUsers.add(new UserResult(u.Id, u.Name, u.Email));
            Set<Id> approvalIds = parseIds(setting.Approval_User_Ids__c);
            if (!approvalIds.isEmpty()) for (User u : [SELECT Id, Name, Email FROM User WHERE Id IN :approvalIds AND IsActive = true WITH USER_MODE ORDER BY Name]) result.approvalUsers.add(new UserResult(u.Id, u.Name, u.Email));
        }
        result.slackEnabled = result.slackEnabled == true; result.teamsEnabled = result.teamsEnabled == true;
        result.slackCredential = CollaborationCredentialService.getOAuthInfo('slack');
        result.teamsCredential = CollaborationCredentialService.getOAuthInfo('microsoft');
        String monitoringJobPattern = OrgMonitorChangeDetectionScheduler.JOB_NAME_PREFIX + '%';
        result.monitoringActive = [
            SELECT COUNT()
            FROM CronTrigger
            WHERE CronJobDetail.Name LIKE :monitoringJobPattern
              AND State NOT IN ('DELETED', 'COMPLETE', 'ERROR')
        ] > 0;
        return result;
    }

    @AuraEnabled
    public static WizardState saveProviderDecision(String provider, Boolean enabled, Integer stage) {
        OrgMonitorSetupSecurity.requireManageSetup();
        if (provider != 'slack' && provider != 'microsoft') throw new AuraHandledException('INVALID_PROVIDER');
        if (stage == null || stage < 3 || stage > 4) throw new AuraHandledException('INVALID_STAGE');
        ChangeLogRuntime__c setting = ChangeLogRuntime__c.getOrgDefaults(); if (setting == null) setting = new ChangeLogRuntime__c();
        if (provider == 'slack') { setting.Slack_Notifications_Enabled__c = enabled == true; if (enabled != true) setting.Slack_Last_Test__c = null; }
        else { setting.Teams_Notifications_Enabled__c = enabled == true; if (enabled != true) setting.Teams_Last_Test__c = null; }
        setting.Last_Saved_Stage__c = stage; upsert setting; return getWizardState();
    }

    // ── User Search ───────────────────────────────────────────────────────────

    /**
     * Returns up to 10 active users whose Name, Email, or Username contains searchTerm.
     * Requires at least 1 character; returns empty list for blank input.
     */
    @AuraEnabled
    public static List<UserResult> searchUsers(String searchTerm) {
        OrgMonitorSetupSecurity.requireManageSetup();
        if (String.isBlank(searchTerm)) {
            return new List<UserResult>();
        }
        String normalized = searchTerm.trim().left(80);
        String term = '%' + normalized + '%';
        List<UserResult> results = new List<UserResult>();
        for (User u : [
            SELECT Id, Name, Email
            FROM   User
            WHERE  IsActive = true
            AND    (Name LIKE :term OR Email LIKE :term OR Username LIKE :term)
            WITH USER_MODE
            ORDER BY Name
            LIMIT  10
        ]) {
            results.add(new UserResult(u.Id, u.Name, u.Email));
        }
        return results;
    }

    // ── Save App Setup ────────────────────────────────────────────────────────

    /**
     * Persists the App Setup step selections:
     *   - deploymentUserIds  : comma-separated User Ids → ChangeLogRuntime__c.Deployment_User_Id__c
     *   - enableApproval     : checkbox              → ChangeLogRuntime__c.Enable_Deployment_Window_Approval__c
     *   - approvalUserIds    : List of User Ids      → ChangeLogRuntime__c.Approval_User_Ids__c and members of Audit_Trail_Queue
     *   - initialRunWindow   : 15 | 30 | 45          → ChangeLogRuntime__c.Initial_Run_Window__c
     *   - skipDeploymentWindowsForSandbox: sandbox-only nominated-user setting
     */
    @AuraEnabled
    public static void saveAppSetup(
        String       deploymentUserIds,
        Boolean      enableApproval,
        List<String> approvalUserIds,
        Integer      initialRunWindow,
        Boolean      skipDeploymentWindowsForSandbox,
        String       unusualHoursStart,
        String       unusualHoursEnd
    ) {
        OrgMonitorSetupSecurity.requireManageSetup();
        try {
            Time unusualStart = parseRequiredTime(unusualHoursStart, 'Unusual Hours Start');
            Time unusualEnd = parseRequiredTime(unusualHoursEnd, 'Unusual Hours End');
            validateSaveInputs(deploymentUserIds, initialRunWindow,
                skipDeploymentWindowsForSandbox, unusualStart, unusualEnd);
            Set<Id> approvalIds = new Set<Id>();
            if (approvalUserIds != null) {
                for (String value : approvalUserIds) {
                    try { approvalIds.add((Id)value); } catch (Exception ignored) { }
                }
            }
            if (enableApproval == true && approvalIds.isEmpty()) {
                throw new AuraHandledException('Please select at least one approval user.');
            }

            ChangeLogRuntime__c setting = ChangeLogRuntime__c.getOrgDefaults();
            if (setting == null) {
                setting = new ChangeLogRuntime__c();
            }
            setting.Deployment_User_Id__c                  = deploymentUserIds;
            setting.Enable_Deployment_Window_Approval__c   = (enableApproval == true);
            setting.Approval_User_Ids__c                   = enableApproval == true ? String.join(new List<Id>(approvalIds), ',') : null;
            setting.Initial_Run_Window__c                  = initialRunWindow;
            setting.Skip_Deployment_Windows_For_Sandbox__c = (skipDeploymentWindowsForSandbox == true);
            setting.Unusual_Hours_Start__c                  = formatTime(unusualStart);
            setting.Unusual_Hours_End__c                    = formatTime(unusualEnd);
            setting.Last_Saved_Stage__c                    = 2;
            upsert setting;

            // Saving Step 2 activates the replacement collector. Re-saving is
            // idempotent: the scheduler maintains exactly one five-minute job.
            scheduleChangeDetectionAsync();

            // GroupMember is a setup object; upsert on ChangeLogRuntime__c (non-setup)
            // in the same transaction causes MIXED_DML_OPERATION — run queue sync async.
            if (enableApproval == true) {
                syncApprovalQueueAsync(
                    new List<String>(setting.Approval_User_Ids__c.split(','))
                );
            }
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to save App Setup settings. Contact your Salesforce administrator if the problem continues.');
        }
    }

    // ── Schedule Compliance Batch ─────────────────────────────────────────────

    /**
     * Backward-compatible Step 5 endpoint. Step 2 already schedules monitoring;
     * this simply ensures the replacement five-minute schedule still exists.
     */
    @AuraEnabled
    public static void scheduleCompliance() {
        OrgMonitorSetupSecurity.requireManageSetup();
        try {
            OrgMonitorChangeDetectionScheduler.scheduleEveryFiveMinutes();
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Private Helpers ───────────────────────────────────────────────────────

    private static void validateSaveInputs(String deploymentUserIds, Integer initialRunWindow,
            Boolean skipDeploymentWindowsForSandbox, Time unusualStart, Time unusualEnd) {
        if (skipDeploymentWindowsForSandbox == true && !organizationContext.isSandbox()) {
            throw new AuraHandledException('Skip Deployment Windows for Sandbox can be enabled only in a Salesforce sandbox.');
        }
        if (skipDeploymentWindowsForSandbox == true && String.isBlank(deploymentUserIds)) {
            throw new AuraHandledException('Select at least one deployment user before enabling Skip Deployment Windows for Sandbox.');
        }
        if (String.isBlank(deploymentUserIds)) {
            throw new AuraHandledException('Please select at least one deployment user.');
        }
        Set<Integer> validWindows = new Set<Integer>{ 15, 30, 45 };
        if (initialRunWindow == null || !validWindows.contains(initialRunWindow)) {
            throw new AuraHandledException('Please select a valid historical run timeframe (15, 30, or 45 days).');
        }
        if (unusualStart == unusualEnd) {
            throw new AuraHandledException('Unusual Hours Start and End must be different.');
        }
    }
    private static Time parseRequiredTime(String value, String label) {
        if (String.isBlank(value)) throw new AuraHandledException(label + ' is required.');
        Matcher match = Pattern.compile('^(\\d{2}):(\\d{2})(?::(\\d{2}))?').matcher(value.trim());
        if (!match.find()) throw new AuraHandledException(label + ' is invalid.');
        Integer hour = Integer.valueOf(match.group(1));
        Integer minute = Integer.valueOf(match.group(2));
        Integer second = String.isBlank(match.group(3)) ? 0 : Integer.valueOf(match.group(3));
        if (hour > 23 || minute > 59 || second > 59)
            throw new AuraHandledException(label + ' is invalid.');
        return Time.newInstance(hour, minute, second, 0);
    }
    private static String formatTime(Time value) {
        if (value == null) return null;
        return String.valueOf(value.hour()).leftPad(2, '0') + ':'
            + String.valueOf(value.minute()).leftPad(2, '0');
    }
    private static Set<Id> parseIds(String csv) { Set<Id> result = new Set<Id>(); if (String.isBlank(csv)) return result; for (String value : csv.split(',')) try { result.add((Id)value.trim()); } catch (Exception ignored) { } return result; }

    // Scheduling is setup work and must run after the custom-setting transaction
    // commits; otherwise Salesforce raises MIXED_DML_OPERATION.
    @future
    private static void scheduleChangeDetectionAsync() {
        OrgMonitorChangeDetectionScheduler.scheduleEveryFiveMinutes();
    }

    @future
    private static void syncApprovalQueueAsync(List<String> userIds) {
        List<Group> queues = [
            SELECT Id
            FROM   Group
            WHERE  DeveloperName = 'Audit_Trail_Queue'
            AND    Type = 'Queue'
            LIMIT  1
        ];
        if (queues.isEmpty()) {
            // Queue does not exist — fail gracefully without blocking setup
            return;
        }
        Id queueId = queues[0].Id;

        List<GroupMember> existing = [
            SELECT Id FROM GroupMember WHERE GroupId = :queueId
        ];
        if (!existing.isEmpty()) {
            delete existing;
        }

        if (!userIds.isEmpty()) {
            List<GroupMember> members = new List<GroupMember>();
            for (String uid : userIds) {
                if (String.isNotBlank(uid)) {
                    members.add(new GroupMember(GroupId = queueId, UserOrGroupId = uid));
                }
            }
            if (!members.isEmpty()) {
                insert members;
            }
        }
    }
}