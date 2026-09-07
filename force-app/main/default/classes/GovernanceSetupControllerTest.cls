@IsTest
private class GovernanceSetupControllerTest {
    private class StubOrganizationContext extends OrgMonitorOrganizationContext {
        private Boolean sandbox;
        StubOrganizationContext(Boolean sandbox) { this.sandbox = sandbox; }
        public override Boolean isSandbox() { return sandbox; }
    }

    private static User currentUser() {
        return [SELECT Id, Name, Email FROM User WHERE Id = :UserInfo.getUserId()];
    }

    @IsTest static void hydratesAndSavesProviderDecisions() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        GovernanceSetupController.organizationContext = new StubOrganizationContext(true);
        User current = currentUser();
        insert new ChangeLogRuntime__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Deployment_User_Id__c = current.Id,
            Enable_Deployment_Window_Approval__c = false,
            Approval_User_Ids__c = current.Id,
            Initial_Run_Window__c = 30,
            Last_Saved_Stage__c = 2,
            Slack_Notifications_Enabled__c = false,
            Teams_Notifications_Enabled__c = false
        );
        GovernanceSetupController.WizardState initial = GovernanceSetupController.getWizardState();
        System.assertEquals(1, initial.deploymentUsers.size());
        System.assertEquals(current.Name, initial.deploymentUsers[0].label);
        System.assertEquals(current.Name, initial.approvalUsers[0].label);
        System.assertEquals(30, initial.initialRunWindow);
        System.assertEquals(false, initial.skipDeploymentWindowsForSandbox, 'The checkbox defaults to false.');
        System.assertEquals(true, initial.isSandbox);
        GovernanceSetupController.saveAppSetup(current.Id, true, new List<String>{ current.Id },
            45, true, '22:00', '06:00');
        ChangeLogRuntime__c persisted = ChangeLogRuntime__c.getOrgDefaults();
        System.assertEquals(current.Id, persisted.Approval_User_Ids__c);
        System.assertEquals(true, persisted.Enable_Deployment_Window_Approval__c);
        System.assertEquals(true, persisted.Skip_Deployment_Windows_For_Sandbox__c);
        System.assertEquals('22:00', persisted.Unusual_Hours_Start__c);
        System.assertEquals('06:00', persisted.Unusual_Hours_End__c);
        System.assertEquals(current.Id, persisted.Deployment_User_Id__c, 'Nominated users must be preserved.');
        System.assertEquals(1, [SELECT COUNT() FROM ChangeLogRuntime__c], 'The org-default record must be updated, not duplicated.');
        System.assertEquals(2, Limits.getFutureCalls(),
            'Approval-enabled Step 2 must enqueue queue synchronization and post-commit scheduling.');
        GovernanceSetupController.WizardState saved = GovernanceSetupController.saveProviderDecision('slack', true, 3);
        System.assertEquals(true, saved.slackEnabled);
        System.assertEquals(3, saved.lastSavedStage);
    }

    @IsTest static void loadsSavedTrueOnlyInSandbox() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        User current = currentUser();
        insert new ChangeLogRuntime__c(
            SetupOwnerId = UserInfo.getOrganizationId(), Deployment_User_Id__c = current.Id,
            Initial_Run_Window__c = 15, Skip_Deployment_Windows_For_Sandbox__c = true
        );
        GovernanceSetupController.organizationContext = new StubOrganizationContext(true);
        System.assertEquals(true, GovernanceSetupController.getWizardState().skipDeploymentWindowsForSandbox);
        GovernanceSetupController.organizationContext = new StubOrganizationContext(false);
        GovernanceSetupController.WizardState productionState = GovernanceSetupController.getWizardState();
        System.assertEquals(false, productionState.isSandbox);
        System.assertEquals(false, productionState.skipDeploymentWindowsForSandbox,
            'An unexpected saved true value must be unavailable in production.');
    }

    @IsTest static void sandboxSavePreservesOtherAppSetupValuesAndRecords() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        GovernanceSetupController.organizationContext = new StubOrganizationContext(true);
        User current = currentUser();
        insert new ChangeLogRuntime__c(
            SetupOwnerId = UserInfo.getOrganizationId(), Deployment_User_Id__c = current.Id,
            Initial_Run_Window__c = 30, Slack_Workspace_Id__c = 'workspace-preserved',
            Skip_Deployment_Windows_For_Sandbox__c = false
        );
        Integer windowsBefore = [SELECT COUNT() FROM Deployment_Window__c];
        Integer changesBefore = [SELECT COUNT() FROM Change_Log__c];

        GovernanceSetupController.saveAppSetup(current.Id, false, new List<String>(),
            45, true, '22:00', '06:00');

        ChangeLogRuntime__c saved = ChangeLogRuntime__c.getOrgDefaults();
        System.assertEquals(true, saved.Skip_Deployment_Windows_For_Sandbox__c);
        System.assertEquals('workspace-preserved', saved.Slack_Workspace_Id__c, 'Fields outside Step 2 must be preserved.');
        System.assertEquals(current.Id, saved.Deployment_User_Id__c);
        System.assertEquals(windowsBefore, [SELECT COUNT() FROM Deployment_Window__c], 'No Deployment Window may be changed.');
        System.assertEquals(changesBefore, [SELECT COUNT() FROM Change_Log__c], 'No audit record may be recalculated.');
    }

    @IsTest static void rejectsSandboxSkipWithoutNominatedUsers() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        GovernanceSetupController.organizationContext = new StubOrganizationContext(true);
        Boolean thrown = false;
        try {
            GovernanceSetupController.saveAppSetup('', false, new List<String>(),
                30, true, '22:00', '06:00');
        } catch (AuraHandledException e) {
            thrown = true;
        }
        System.assert(thrown, 'Sandbox skip must require a nominated deployment user.');
        System.assertEquals(0, [SELECT COUNT() FROM ChangeLogRuntime__c]);
    }

    @IsTest static void rejectsSandboxSkipInProduction() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        GovernanceSetupController.organizationContext = new StubOrganizationContext(false);
        Boolean thrown = false;
        try {
            GovernanceSetupController.saveAppSetup(UserInfo.getUserId(), false, new List<String>(),
                30, true, '22:00', '06:00');
        } catch (AuraHandledException e) {
            thrown = true;
        }
        System.assert(thrown, 'A direct Apex request must not enable sandbox skip in production.');
        System.assertEquals(0, [SELECT COUNT() FROM ChangeLogRuntime__c]);
    }

    @IsTest static void rejectsIdenticalOrMissingUnusualHours() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        GovernanceSetupController.organizationContext = new StubOrganizationContext(true);
        for (List<String> values : new List<List<String>>{
                new List<String>{ '22:00', '22:00' }, new List<String>{ '', '06:00' } }) {
            Boolean thrown = false;
            try {
                GovernanceSetupController.saveAppSetup(UserInfo.getUserId(), false,
                    new List<String>(), 30, false, values[0], values[1]);
            } catch (AuraHandledException error) { thrown = true; }
            System.assert(thrown, 'Invalid unusual-hours settings must be rejected.');
        }
    }

    @IsTest static void readsTrustedOrganizationContextOncePerInstance() {
        OrgMonitorOrganizationContext context = new OrgMonitorOrganizationContext();
        Boolean first = context.isSandbox();
        Boolean second = context.isSandbox();
        System.assertEquals(first, second, 'The trusted sandbox value must be cached for the transaction.');
    }

    @IsTest static void searchesOnlyThroughTheAuthorizedSetupEndpoint() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        System.assertEquals(0, GovernanceSetupController.searchUsers(' ').size());
        List<GovernanceSetupController.UserResult> matches = GovernanceSetupController.searchUsers(UserInfo.getUserName());
        System.assert(!matches.isEmpty(), 'The active current user should be returned by username search.');
        System.assertEquals(UserInfo.getUserId(), matches[0].id);
    }
    @IsTest static void rejectsInvalidProviderState() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        Boolean thrown = false;
        try { GovernanceSetupController.saveProviderDecision('unknown', true, 3); } catch (AuraHandledException e) { thrown = true; }
        System.assert(thrown);
    }
    @IsTest static void rejectsUnauthorizedSetupAccess() {
        OrgMonitorSetupSecurity.testPermissionGranted = false;
        Boolean thrown = false;
        try { GovernanceSetupController.getWizardState(); } catch (AuraHandledException e) { thrown = true; }
        System.assert(thrown, 'Setup endpoints must require the packaged custom permission.');
    }

    @IsTest static void schedulerMaintainsExactlyOneFiveMinuteScheduleSet() {
        OrgMonitorSetupSecurity.testPermissionGranted = true;
        GovernanceSetupController.organizationContext = new StubOrganizationContext(true);
        OrgMonitorChangeDetectionScheduler.scheduleEveryFiveMinutes();
        OrgMonitorChangeDetectionScheduler.scheduleEveryFiveMinutes();

        String jobPattern = OrgMonitorChangeDetectionScheduler.JOB_NAME_PREFIX + '%';
        List<CronTrigger> jobs = [
            SELECT CronExpression
            FROM CronTrigger
            WHERE CronJobDetail.Name LIKE :jobPattern
              AND State NOT IN ('DELETED', 'COMPLETE', 'ERROR')
        ];
        System.assertEquals(12, jobs.size(), 'Step 2 re-save must retain one 12-job five-minute schedule set.');
        Set<String> cronExpressions = new Set<String>();
        for (CronTrigger job : jobs) cronExpressions.add(job.CronExpression);
        System.assert(cronExpressions.contains('0 0 * * * ?'));
        System.assert(cronExpressions.contains('0 55 * * * ?'));
    }
}