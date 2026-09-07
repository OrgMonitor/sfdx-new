@IsTest
private class OrgMonitorChangeProcessorTest {
    private class FakeLoginDataProvider implements OrgMonitorChangeProcessor.LoginDataProvider {
        Boolean historyReadable = true;
        Boolean geoReadable = true;
        Integer historyQueries = 0;
        Integer geoQueries = 0;
        Set<Id> requestedActors = new Set<Id>();
        List<LoginHistory> histories = new List<LoginHistory>();
        Map<Id, LoginGeo> geos = new Map<Id, LoginGeo>();
        public Boolean loginHistoryReadable() { return historyReadable; }
        public List<LoginHistory> queryLoginHistories(Set<Id> actorIds, Datetime latestChangeTime) {
            historyQueries++;
            requestedActors.addAll(actorIds);
            return histories;
        }
        public Boolean loginGeoReadable() { return geoReadable; }
        public Map<Id, LoginGeo> queryLoginGeos(Set<Id> geoIds) {
            geoQueries++;
            Map<Id, LoginGeo> result = new Map<Id, LoginGeo>();
            for (Id geoId : geoIds) if (geos.containsKey(geoId)) result.put(geoId, geos.get(geoId));
            return result;
        }
    }
    private static OrgMonitorChangeRunConfig.Rule rule(String action, String section,
            String severity, Boolean ignore) {
        OrgMonitorChangeRunConfig.Rule value = new OrgMonitorChangeRunConfig.Rule();
        value.key = 'RULE_' + action;
        value.matchType = String.isBlank(section) ? 'EXACT_ACTION' : 'EXACT_ACTION_SECTION';
        value.action = action; value.section = section; value.operation = 'UPDATE';
        value.metadataType = 'PermissionSet'; value.category = 'Access Management';
        value.severity = severity; value.priority = 100; value.ignore = ignore;
        value.targetRegex = '.*"([^"]+)".*'; value.componentGroup = 1;
        return value;
    }

    private static OrgMonitorChangeRunConfig.Rule deletedFieldRule() {
        OrgMonitorChangeRunConfig.Rule value = rule('deletedCF', null, 'CRITICAL', false);
        value.key = 'AR_deletedCF_ANY_SECTION'; value.operation = 'DELETE_OR_REMOVE';
        value.metadataType = 'Custom Field'; value.category = 'Data Model';
        value.riskDescription = 'A custom field was deleted. Field deletion can disrupt automation.';
        value.targetRegex = '^Deleted custom field\\s+(.+)$'; value.componentGroup = 1;
        return value;
    }

    private static OrgMonitorChangeRunConfig config(List<OrgMonitorChangeRunConfig.Rule> rules,
            Boolean sandbox, Boolean skip, Set<Id> appUsers) {
        Datetime cutoff = System.now().addMinutes(1);
        return OrgMonitorChangeRunConfig.forTest(cutoff, cutoff.addHours(-1), 15,
            false, sandbox, skip, appUsers, rules);
    }

    private static SObject audit(String idValue, String action, String section,
            String display, Datetime changedAt, String delegateUser) {
        Map<String, Object> fields = new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'SetupAuditTrail' },
            'Id' => idValue, 'Action' => action, 'Section' => section,
            'Display' => display, 'CreatedById' => UserInfo.getUserId(),
            'CreatedDate' => changedAt, 'DelegateUser' => delegateUser
        };
        return (SetupAuditTrail) JSON.deserialize(JSON.serialize(fields), SetupAuditTrail.class);
    }
    private static String sourceKey(String value) { return String.valueOf((Id) value); }

    private static User internalUser(String suffix) {
        User current = [SELECT ProfileId FROM User WHERE Id = :UserInfo.getUserId()];
        return new User(Alias = ('u' + suffix).left(8), Email = suffix + '@example.invalid',
            EmailEncodingKey = 'UTF-8', LastName = 'Delegate ' + suffix,
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = current.ProfileId,
            TimeZoneSidKey = 'Australia/Sydney',
            Username = suffix + '.' + System.now().getTime() + '@example.invalid');
    }

    @IsTest static void exactRuleMapsEvidenceAndNoWindowReason() {
        Datetime changedAt = System.now();
        OrgMonitorChangeProcessor.Outcome outcome = new OrgMonitorChangeProcessor().process(
            new List<SObject>{ audit('0Ym000000000001', 'PermSetAssign', 'Manage Users',
                'Updated "Service Agent"', changedAt, null) },
            config(new List<OrgMonitorChangeRunConfig.Rule>{
                rule('PermSetAssign', 'Manage Users', 'CRITICAL', false)
            }, false, false, null), 'OM-TEST-1');
        System.assertEquals(true, outcome.successful);
        System.assertEquals(1, outcome.createdCount);
        Change_Log__c row = [SELECT External_Id__c, Effective_Actor__c, Changed_By_User__c,
            Metadata_Type__c, Component_Name__c, Severity__c, Non_Compliant__c,
            Compliance_Reason_Code__c, Compliance_Reason__c, Run_Correlation_Id__c,
            Change_Summary__c
            FROM Change_Log__c WHERE Run_Correlation_Id__c = 'OM-TEST-1'];
        System.assertEquals(UserInfo.getUserId(), row.Effective_Actor__c);
        System.assertEquals(UserInfo.getUserId(), row.Changed_By_User__c);
        System.assertEquals('Service Agent', row.Component_Name__c);
        System.assertEquals('CRITICAL', row.Severity__c);
        System.assertEquals(true, row.Non_Compliant__c);
        System.assertEquals('NO_DEPLOYMENT_WINDOW', row.Compliance_Reason_Code__c);
        System.assert(row.Compliance_Reason__c.startsWith('Non-compliant'));
        System.assert(row.Change_Summary__c.startsWith('Updated PermissionSet “Service Agent”'));
        System.assert(row.Change_Summary__c.contains(row.Compliance_Reason__c));
    }

    @IsTest static void windowUsesInclusiveStartExclusiveEndAndNomination() {
        Datetime startAt = System.now().addMinutes(-10);
        Datetime endAt = System.now().addMinutes(10);
        Deployment_Window__c window = new Deployment_Window__c(
            Start_Date_Time__c = startAt, End_Date_Time__c = endAt, Status__c = 'Active');
        insert window;
        insert new Authorised_Deployment_User__c(Deployment_Window__c = window.Id,
            User__c = UserInfo.getUserId(), Deployment_Role__c = 'Developer');
        OrgMonitorChangeRunConfig cfg = config(new List<OrgMonitorChangeRunConfig.Rule>{
            rule('changedApexClass', null, 'HIGH', false)
        }, false, false, null);
        OrgMonitorChangeProcessor processor = new OrgMonitorChangeProcessor();
        OrgMonitorChangeProcessor.Outcome atStart = processor.process(new List<SObject>{
            audit('0Ym000000000002', 'changedApexClass', 'Apex Classes',
                'Changed "Example"', startAt, null)
        }, cfg, 'OM-TEST-2');
        OrgMonitorChangeProcessor.Outcome atEnd = processor.process(new List<SObject>{
            audit('0Ym000000000003', 'changedApexClass', 'Apex Classes',
                'Changed "Example"', endAt, null)
        }, cfg, 'OM-TEST-2');
        System.assertEquals(1, atStart.createdCount);
        System.assertEquals(1, atEnd.createdCount);
        Map<String, Change_Log__c> rows = new Map<String, Change_Log__c>();
        for (Change_Log__c row : [SELECT External_Id__c, Non_Compliant__c,
                Compliance_Reason_Code__c FROM Change_Log__c]) rows.put(row.External_Id__c, row);
        System.assertEquals(false, rows.get(sourceKey('0Ym000000000002')).Non_Compliant__c);
        System.assertEquals('WINDOW_APPROVAL_NOT_REQUIRED',
            rows.get(sourceKey('0Ym000000000002')).Compliance_Reason_Code__c);
        System.assertEquals('NO_DEPLOYMENT_WINDOW',
            rows.get(sourceKey('0Ym000000000003')).Compliance_Reason_Code__c);
    }

    @IsTest static void duplicateAndIgnoredRuleCreateNothing() {
        insert new Change_Log__c(External_Id__c = sourceKey('0Ym000000000004'));
        List<SObject> rows = new List<SObject>{
            audit('0Ym000000000004', 'known', 'Setup', 'Known', System.now(), null),
            audit('0Ym000000000005', 'ignored', 'Setup', 'Ignored', System.now(), null)
        };
        OrgMonitorChangeProcessor.Outcome outcome = new OrgMonitorChangeProcessor().process(rows,
            config(new List<OrgMonitorChangeRunConfig.Rule>{
                rule('known', null, 'LOW', false), rule('ignored', null, 'LOW', true)
            }, false, false, null), 'OM-TEST-3');
        System.assertEquals(0, outcome.createdCount);
        System.assertEquals(1, [SELECT COUNT() FROM Change_Log__c]);
    }

    @IsTest static void unknownInternalChangeIsPersistedAsUnclassified() {
        OrgMonitorChangeProcessor.Outcome outcome = new OrgMonitorChangeProcessor().process(
            new List<SObject>{ audit('0Ym000000000006', 'futureAction', 'Future Setup',
                'Changed something new', System.now(), null) },
            config(new List<OrgMonitorChangeRunConfig.Rule>(), false, false, null), 'OM-TEST-4');
        System.assertEquals(1, outcome.createdCount);
        Change_Log__c row = [SELECT Metadata_Type__c, Severity__c, Non_Compliant__c,
            Change_Summary__c, Compliance_Reason__c
            FROM Change_Log__c WHERE Run_Correlation_Id__c = 'OM-TEST-4'];
        System.assertEquals('Unclassified', row.Metadata_Type__c);
        System.assertEquals('LOW', row.Severity__c);
        System.assertEquals(true, row.Non_Compliant__c);
        System.assert(row.Change_Summary__c.startsWith('Changed something new.'));
        System.assert(row.Change_Summary__c.contains(row.Compliance_Reason__c));
    }

    @IsTest static void sandboxSkipRequiresConfiguredEffectiveActor() {
        OrgMonitorChangeProcessor.Outcome outcome = new OrgMonitorChangeProcessor().process(
            new List<SObject>{ audit('0Ym000000000007', 'known', 'Setup', 'Changed', System.now(), null) },
            config(new List<OrgMonitorChangeRunConfig.Rule>{ rule('known', null, 'LOW', false) },
                true, true, new Set<Id>{ UserInfo.getUserId() }), 'OM-TEST-5');
        System.assertEquals(1, outcome.createdCount);
        Change_Log__c row = [SELECT Non_Compliant__c, Compliance_Reason_Code__c,
            Change_Summary__c, Compliance_Reason__c
            FROM Change_Log__c WHERE Run_Correlation_Id__c = 'OM-TEST-5'];
        System.assertEquals(false, row.Non_Compliant__c);
        System.assertEquals('SANDBOX_WINDOW_SKIP', row.Compliance_Reason_Code__c);
        System.assert(String.isNotBlank(row.Change_Summary__c));
        System.assert(row.Change_Summary__c.contains(row.Compliance_Reason__c));
    }

    @IsTest static void failedPersistenceIsReported() {
        OrgMonitorChangeRunConfig.Rule invalid = rule('known', null, 'NOT_A_PICKLIST_VALUE', false);
        OrgMonitorChangeProcessor.Outcome outcome = new OrgMonitorChangeProcessor().process(
            new List<SObject>{ audit('0Ym000000000008', 'known', 'Setup', 'Changed', System.now(), null) },
            config(new List<OrgMonitorChangeRunConfig.Rule>{ invalid }, false, false, null), 'OM-TEST-6');
        System.assertEquals(false, outcome.successful);
        System.assertEquals(0, outcome.createdCount);
    }

    @IsTest static void delegatedInternalUserIsEffectiveActorAndActingUserIsRetained() {
        User delegate = internalUser('delegate');
        insert delegate;
        OrgMonitorChangeRunConfig.Rule delegatedRule = rule('known', null, 'HIGH', false);
        delegatedRule.actionScore = 4; delegatedRule.scoreWeight = 14;
        OrgMonitorChangeProcessor.Outcome outcome = new OrgMonitorChangeProcessor().process(
            new List<SObject>{ audit('0Ym000000000009', 'known', 'Setup',
                'Changed "Delegated Component"', System.now(), delegate.Username) },
            config(new List<OrgMonitorChangeRunConfig.Rule>{ delegatedRule },
                false, false, null), 'OM-DELEGATED');

        System.assertEquals(1, outcome.createdCount);
        Change_Log__c row = [SELECT Effective_Actor__c, Changed_By_User__c,
            Is_Delegated_Access__c, Delegate_Username__c, Change_Summary__c,
            Severity__c, Risk_Description__c, Action_Score__c, Score_Weight__c, Weighted_Score__c
            FROM Change_Log__c WHERE Run_Correlation_Id__c = 'OM-DELEGATED'];
        System.assertEquals(delegate.Id, row.Effective_Actor__c);
        System.assertEquals(UserInfo.getUserId(), row.Changed_By_User__c);
        System.assertEquals(true, row.Is_Delegated_Access__c);
        System.assertEquals(delegate.Username, row.Delegate_Username__c);
        System.assert(row.Change_Summary__c.contains('while logged in as'));
        System.assertEquals('CRITICAL', row.Severity__c);
        System.assert(row.Risk_Description__c.contains('Login-As activity'));
        System.assertEquals(4, row.Action_Score__c);
        System.assertEquals(14, row.Score_Weight__c);
        System.assertEquals(56, row.Weighted_Score__c);
    }

    @IsTest static void unresolvedDelegateIsExcluded() {
        OrgMonitorChangeProcessor.Outcome outcome = new OrgMonitorChangeProcessor().process(
            new List<SObject>{ audit('0Ym000000000010', 'known', 'Setup', 'Changed',
                System.now(), 'missing.delegate@example.invalid') },
            config(new List<OrgMonitorChangeRunConfig.Rule>{ rule('known', null, 'LOW', false) },
                false, false, null), 'OM-UNRESOLVED');
        System.assertEquals(0, outcome.createdCount);
        System.assertEquals(0, [SELECT COUNT() FROM Change_Log__c
            WHERE Run_Correlation_Id__c = 'OM-UNRESOLVED']);
    }

    @IsTest static void higherPriorityExactRuleWinsAndFailedExtractionStaysBlank() {
        OrgMonitorChangeRunConfig.Rule low = rule('priorityAction', null, 'LOW', false);
        low.key = 'LOW_RULE'; low.priority = 10;
        OrgMonitorChangeRunConfig.Rule high = rule('priorityAction', null, 'CRITICAL', false);
        high.key = 'HIGH_RULE'; high.priority = 200; high.targetRegex = 'Value: (.+)';
        OrgMonitorChangeProcessor.Outcome outcome = new OrgMonitorChangeProcessor().process(
            new List<SObject>{ audit('0Ym000000000014', 'priorityAction', 'Setup',
                'No extractable target', System.now(), null) },
            config(new List<OrgMonitorChangeRunConfig.Rule>{ low, high }, false, false, null),
            'OM-PRIORITY');
        System.assertEquals(1, outcome.createdCount);
        Change_Log__c row = [SELECT Severity__c, Classification_Rule_Key__c,
            Component_Name__c, Metadata_Type__c, Non_Compliant__c, Change_Summary__c
            FROM Change_Log__c WHERE Run_Correlation_Id__c = 'OM-PRIORITY'];
        System.assertEquals('CRITICAL', row.Severity__c);
        System.assertEquals('HIGH_RULE', row.Classification_Rule_Key__c);
        System.assertEquals(null, row.Component_Name__c);
        System.assertEquals('PermissionSet', row.Metadata_Type__c);
        System.assertEquals(true, row.Non_Compliant__c,
            'Classification severity and compliance must remain independent.');
        System.assert(row.Change_Summary__c.startsWith('No extractable target.'));
    }

    @IsTest static void coveringWindowWithoutNominationIsNonCompliant() {
        Datetime unusualAt = Datetime.newInstanceGMT(2026, 1, 1, 12, 30, 0);
        Deployment_Window__c window = new Deployment_Window__c(
            Start_Date_Time__c = unusualAt.addHours(-1),
            End_Date_Time__c = unusualAt.addHours(1), Status__c = 'Active');
        insert window;
        OrgMonitorChangeProcessor.Outcome outcome = new OrgMonitorChangeProcessor().process(
            new List<SObject>{ audit('0Ym000000000015', 'known', 'Setup', 'Changed',
                unusualAt, null) },
            config(new List<OrgMonitorChangeRunConfig.Rule>{ rule('known', null, 'LOW', false) },
                false, false, null), 'OM-NOMINATION');
        System.assertEquals(1, outcome.createdCount);
        Change_Log__c row = [SELECT Non_Compliant__c, Compliance_Reason_Code__c,
            Compliance_Reason__c, Matched_Deployment_Window__c, Unusual_Hours__c,
            Change_Timing_Indicator__c
            FROM Change_Log__c WHERE Run_Correlation_Id__c = 'OM-NOMINATION'];
        System.assertEquals(true, row.Non_Compliant__c);
        System.assertEquals('USER_NOT_NOMINATED', row.Compliance_Reason_Code__c);
        System.assert(row.Compliance_Reason__c.startsWith('Non-compliant'));
        System.assertEquals(window.Id, row.Matched_Deployment_Window__c);
        System.assertEquals(true, row.Unusual_Hours__c);
        System.assertEquals('🌙 Odd hours', row.Change_Timing_Indicator__c,
            'USER_NOT_NOMINATED is inside a window and must not say outside window.');
    }

    @IsTest static void unusualHoursInsideCompliantWindowRetainsOddHoursIndicator() {
        Datetime unusualAt = Datetime.newInstanceGMT(2026, 1, 1, 12, 30, 0);
        Deployment_Window__c window = new Deployment_Window__c(
            Start_Date_Time__c = unusualAt.addHours(-1),
            End_Date_Time__c = unusualAt.addHours(1), Status__c = 'Active');
        insert window;
        insert new Authorised_Deployment_User__c(Deployment_Window__c = window.Id,
            User__c = UserInfo.getUserId(), Deployment_Role__c = 'Developer');
        new OrgMonitorChangeProcessor().process(new List<SObject>{
            audit('0Ym000000000026', 'known', 'Setup', 'Changed', unusualAt, null)
        }, config(new List<OrgMonitorChangeRunConfig.Rule>{ rule('known', null, 'LOW', false) },
            false, false, null), 'OM-ODD-COMPLIANT');
        Change_Log__c row = [SELECT Unusual_Hours__c, Change_Timing_Indicator__c,
            Non_Compliant__c, Compliance_Reason_Code__c FROM Change_Log__c
            WHERE Run_Correlation_Id__c = 'OM-ODD-COMPLIANT'];
        System.assertEquals(true, row.Unusual_Hours__c);
        System.assertEquals(false, row.Non_Compliant__c);
        System.assertEquals('WINDOW_APPROVAL_NOT_REQUIRED', row.Compliance_Reason_Code__c);
        System.assertEquals('🌙 Odd hours', row.Change_Timing_Indicator__c);
    }

    @IsTest static void deletedFieldMatchesExactActionWithAnySectionAndExtractsLabel() {
        User delegate = internalUser('fielddelete'); insert delegate;
        List<SObject> audits = new List<SObject>{
            audit('0Ym000000000016', '  deletedCF  ', 'Customize Accounts',
                'Deleted custom field Active', System.now(), delegate.Username),
            audit('0Ym000000000017', 'deletedCF', null,
                'Deleted custom field Is Active', System.now(), delegate.Username)
        };
        OrgMonitorChangeProcessor.Outcome outcome = new OrgMonitorChangeProcessor().process(audits,
            config(new List<OrgMonitorChangeRunConfig.Rule>{ deletedFieldRule() }, false, false, null),
            'OM-DELETED-CF');
        System.assertEquals(2, outcome.createdCount);
        List<Change_Log__c> rows = [SELECT Action__c, Section__c, Change_Operation__c,
            Metadata_Type__c, Category__c, Component_Name__c, Severity__c,
            Classification_Rule_Key__c, Risk_Description__c, Effective_Actor__c,
            Changed_By_User__c, Is_Delegated_Access__c, Delegate_Username__c, Change_Summary__c
            FROM Change_Log__c WHERE Run_Correlation_Id__c = 'OM-DELETED-CF'
            ORDER BY External_Id__c];
        System.assertEquals('Active', rows[0].Component_Name__c);
        System.assertEquals('Is Active', rows[1].Component_Name__c);
        for (Change_Log__c row : rows) {
            System.assertEquals('DELETE_OR_REMOVE', row.Change_Operation__c);
            System.assertEquals('Custom Field', row.Metadata_Type__c);
            System.assertEquals('Data Model', row.Category__c);
            System.assertEquals('CRITICAL', row.Severity__c);
            System.assertEquals('AR_deletedCF_ANY_SECTION', row.Classification_Rule_Key__c);
            System.assert(row.Risk_Description__c.contains('Login-As activity'));
            System.assertEquals(delegate.Id, row.Effective_Actor__c);
            System.assertEquals(UserInfo.getUserId(), row.Changed_By_User__c);
            System.assertEquals(true, row.Is_Delegated_Access__c);
            System.assertEquals(delegate.Username, row.Delegate_Username__c);
            System.assert(row.Change_Summary__c.startsWith('Deleted Custom Field'));
            System.assert(!row.Change_Summary__c.contains('deletedCF'));
        }
    }

    @IsTest static void delegatedEffectiveActorDrivesWindowNomination() {
        User delegate = internalUser('notnominated'); insert delegate;
        Deployment_Window__c window = new Deployment_Window__c(
            Start_Date_Time__c = System.now().addHours(-1),
            End_Date_Time__c = System.now().addHours(1), Status__c = 'Active');
        insert window;
        insert new Authorised_Deployment_User__c(Deployment_Window__c = window.Id,
            User__c = UserInfo.getUserId(), Deployment_Role__c = 'Developer');
        new OrgMonitorChangeProcessor().process(new List<SObject>{
            audit('0Ym000000000018', 'deletedCF', null, 'Deleted custom field Active',
                System.now(), delegate.Username)
        }, config(new List<OrgMonitorChangeRunConfig.Rule>{ deletedFieldRule() }, false, false, null),
            'OM-DELEGATE-WINDOW');
        Change_Log__c row = [SELECT Effective_Actor__c, Compliance_Reason_Code__c,
            Compliance_Reason__c, Non_Compliant_Reason__c, Matched_Deployment_Window__c
            FROM Change_Log__c WHERE Run_Correlation_Id__c = 'OM-DELEGATE-WINDOW'];
        System.assertEquals(delegate.Id, row.Effective_Actor__c);
        System.assertEquals('USER_NOT_NOMINATED', row.Compliance_Reason_Code__c);
        System.assert(row.Compliance_Reason__c.contains('Delegate notnominated'));
        System.assert(row.Non_Compliant_Reason__c.contains('Delegate notnominated'));
        System.assertEquals(window.Id, row.Matched_Deployment_Window__c);
    }

    @IsTest static void standaloneLoginAsEventIdentifiesAdministratorAndTarget() {
        User current = [SELECT Username, Name FROM User WHERE Id = :UserInfo.getUserId()];
        User target = internalUser('logintarget'); insert target;
        target = [SELECT Id, Name FROM User WHERE Id = :target.Id];
        OrgMonitorChangeRunConfig.Rule loginRule = rule(
            'suOrgAdminLogin', 'Manage Users', 'CRITICAL', false);
        loginRule.operation = 'Logged In As'; loginRule.metadataType = 'Login-As Access';
        loginRule.category = 'Security & Access';
        loginRule.targetRegex = '^Logged in using Login-As access for\\s+(.+)$';
        loginRule.componentGroup = 1;
        new OrgMonitorChangeProcessor().process(new List<SObject>{
            audit('0Ym000000000019', 'suOrgAdminLogin', 'Manage Users',
                'Logged in using Login-As access for ' + target.Name, System.now(), current.Username)
        }, config(new List<OrgMonitorChangeRunConfig.Rule>{ loginRule }, false, false, null),
            'OM-LOGIN-AS');
        Change_Log__c row = [SELECT Effective_Actor__c, Changed_By_User__c, Severity__c,
            Category__c, Component_Name__c, Change_Summary__c
            FROM Change_Log__c WHERE Run_Correlation_Id__c = 'OM-LOGIN-AS'];
        System.assertEquals(UserInfo.getUserId(), row.Effective_Actor__c);
        System.assertEquals(target.Id, row.Changed_By_User__c);
        System.assertEquals('CRITICAL', row.Severity__c);
        System.assertEquals('Security & Access', row.Category__c);
        System.assertEquals(target.Name, row.Component_Name__c);
        System.assert(row.Change_Summary__c.startsWith(current.Name + ' logged in as'));
        System.assert(row.Change_Summary__c.contains('logged in as ' + target.Name));
    }

    @IsTest static void selectsLatestSuccessfulLoginAtOrBeforeChange() {
        Datetime changeTime = Datetime.newInstanceGMT(2026, 9, 5, 6, 30, 0);
        List<LoginHistory> histories = new List<LoginHistory>{
            loginHistory(changeTime.addMinutes(2), 'Success', '203.0.113.3'),
            loginHistory(changeTime.addMinutes(-20), 'Success', '203.0.113.1'),
            loginHistory(changeTime.addMinutes(-1), 'Invalid Password', '203.0.113.4'),
            loginHistory(changeTime.addMinutes(-5), 'Success', '203.0.113.2')
        };
        LoginHistory selected = OrgMonitorChangeProcessor.selectMostRecentSuccessfulLogin(
            histories, changeTime);
        System.assertEquals(changeTime.addMinutes(-5), selected.LoginTime);
        System.assertEquals('203.0.113.2', selected.SourceIp);
        System.assertEquals(null, OrgMonitorChangeProcessor.selectMostRecentSuccessfulLogin(
            histories, changeTime.addHours(-2)));
    }

    @IsTest static void enrichesNormalActorFromSelectedLoginAndGeoInBulk() {
        Datetime changeTime = Datetime.newInstanceGMT(2026, 9, 5, 6, 30, 0);
        Id geoId = (Id)'04F000000000001AAA';
        FakeLoginDataProvider provider = new FakeLoginDataProvider();
        provider.histories.addAll(new List<LoginHistory>{
            loginHistory(UserInfo.getUserId(), changeTime.addMinutes(2), 'Success',
                '203.0.113.99', '198.51.100.99', geoId),
            loginHistory(UserInfo.getUserId(), changeTime.addMinutes(-1), 'Invalid Password',
                '203.0.113.98', null, geoId),
            loginHistory(UserInfo.getUserId(), changeTime.addMinutes(-5), 'Success',
                '203.0.113.10', null, geoId)
        });
        provider.geos.put(geoId, loginGeo(geoId, 'Sydney', 'New South Wales', 'Australia', '2000'));
        OrgMonitorChangeProcessor processor = new OrgMonitorChangeProcessor();
        processor.loginDataProvider = provider;
        OrgMonitorChangeProcessor.Outcome outcome = processor.process(new List<SObject>{
            audit('0Ym000000000020', 'known', 'Setup', 'Changed A', changeTime, null),
            audit('0Ym000000000021', 'known', 'Setup', 'Changed B', changeTime, null)
        }, config(new List<OrgMonitorChangeRunConfig.Rule>{ rule('known', null, 'HIGH', false) },
            false, false, null), 'OM-LOGIN-ENRICH');

        System.assertEquals(2, outcome.createdCount);
        System.assertEquals(1, provider.historyQueries, 'LoginHistory must be queried once per scope.');
        System.assertEquals(1, provider.geoQueries, 'LoginGeo must be queried once per scope.');
        System.assertEquals(new Set<Id>{ UserInfo.getUserId() }, provider.requestedActors);
        for (Change_Log__c row : [SELECT Source_IP__c, Forwarded_For_IP__c,
                User_Location_City__c, User_Location_State__c, User_Location_Country__c,
                User_Location_Postal_Code__c, IP_Address__c, Severity__c, Non_Compliant__c
                FROM Change_Log__c WHERE Run_Correlation_Id__c = 'OM-LOGIN-ENRICH']) {
            System.assertEquals('203.0.113.10', row.Source_IP__c);
            System.assertEquals(null, row.Forwarded_For_IP__c);
            System.assertEquals('Sydney', row.User_Location_City__c);
            System.assertEquals('New South Wales', row.User_Location_State__c);
            System.assertEquals('Australia', row.User_Location_Country__c);
            System.assertEquals('2000', row.User_Location_Postal_Code__c);
            System.assertEquals(null, row.IP_Address__c, 'Generic IP placeholder must stay blank.');
            System.assertEquals('HIGH', row.Severity__c);
            System.assertEquals(true, row.Non_Compliant__c);
        }
    }

    @IsTest static void delegatedEnrichmentUsesDelegateAndNotActingAsUser() {
        User delegate = internalUser('geoactor'); insert delegate;
        Datetime changeTime = System.now();
        FakeLoginDataProvider provider = new FakeLoginDataProvider();
        provider.histories.add(loginHistory(delegate.Id, changeTime.addMinutes(-2), 'Success',
            '203.0.113.20', '198.51.100.20', null));
        provider.histories.add(loginHistory(UserInfo.getUserId(), changeTime.addMinutes(-1), 'Success',
            '203.0.113.21', null, null));
        OrgMonitorChangeProcessor processor = new OrgMonitorChangeProcessor();
        processor.loginDataProvider = provider;
        processor.process(new List<SObject>{
            audit('0Ym000000000022', 'known', 'Setup', 'Changed', changeTime, delegate.Username)
        }, config(new List<OrgMonitorChangeRunConfig.Rule>{ rule('known', null, 'HIGH', false) },
            false, false, null), 'OM-DELEGATE-GEO');

        Change_Log__c row = [SELECT Effective_Actor__c, Changed_By_User__c, Source_IP__c,
            Forwarded_For_IP__c, Severity__c FROM Change_Log__c
            WHERE Run_Correlation_Id__c = 'OM-DELEGATE-GEO'];
        System.assertEquals(new Set<Id>{ delegate.Id }, provider.requestedActors);
        System.assertEquals(delegate.Id, row.Effective_Actor__c);
        System.assertEquals(UserInfo.getUserId(), row.Changed_By_User__c);
        System.assertEquals('203.0.113.20', row.Source_IP__c);
        System.assertEquals('198.51.100.20', row.Forwarded_For_IP__c);
        System.assertEquals('CRITICAL', row.Severity__c, 'Delegated severity floor must be unchanged.');
    }

    @IsTest static void inaccessibleGeoRetainsLoginIpsAndSkipsGeoQuery() {
        Datetime changeTime = System.now();
        Id geoId = (Id)'04F000000000002AAA';
        FakeLoginDataProvider provider = new FakeLoginDataProvider();
        provider.geoReadable = false;
        provider.histories.add(loginHistory(UserInfo.getUserId(), changeTime.addMinutes(-1),
            'Success', '203.0.113.30', '198.51.100.30', geoId));
        OrgMonitorChangeProcessor processor = new OrgMonitorChangeProcessor();
        processor.loginDataProvider = provider;
        processor.process(new List<SObject>{ audit('0Ym000000000023', 'known', 'Setup',
            'Changed', changeTime, null) }, config(new List<OrgMonitorChangeRunConfig.Rule>{
                rule('known', null, 'LOW', false) }, false, false, null), 'OM-NO-GEO-ACCESS');

        Change_Log__c row = [SELECT Source_IP__c, Forwarded_For_IP__c,
            User_Location_City__c, User_Location_State__c, User_Location_Country__c,
            User_Location_Postal_Code__c FROM Change_Log__c
            WHERE Run_Correlation_Id__c = 'OM-NO-GEO-ACCESS'];
        System.assertEquals(1, provider.historyQueries);
        System.assertEquals(0, provider.geoQueries);
        System.assertEquals('203.0.113.30', row.Source_IP__c);
        System.assertEquals('198.51.100.30', row.Forwarded_For_IP__c);
        System.assertEquals(null, row.User_Location_City__c);
        System.assertEquals(null, row.User_Location_State__c);
        System.assertEquals(null, row.User_Location_Country__c);
        System.assertEquals(null, row.User_Location_Postal_Code__c);
    }

    @IsTest static void inaccessibleLoginHistoryLeavesAllEnrichmentBlank() {
        FakeLoginDataProvider provider = new FakeLoginDataProvider();
        provider.historyReadable = false;
        OrgMonitorChangeProcessor processor = new OrgMonitorChangeProcessor();
        processor.loginDataProvider = provider;
        processor.process(new List<SObject>{ audit('0Ym000000000024', 'known', 'Setup',
            'Changed', System.now(), null) }, config(new List<OrgMonitorChangeRunConfig.Rule>{
                rule('known', null, 'LOW', false) }, false, false, null), 'OM-NO-LOGIN-ACCESS');
        Change_Log__c row = [SELECT Source_IP__c, Forwarded_For_IP__c, User_Location_City__c
            FROM Change_Log__c WHERE Run_Correlation_Id__c = 'OM-NO-LOGIN-ACCESS'];
        System.assertEquals(0, provider.historyQueries);
        System.assertEquals(0, provider.geoQueries);
        System.assertEquals(null, row.Source_IP__c);
        System.assertEquals(null, row.Forwarded_For_IP__c);
        System.assertEquals(null, row.User_Location_City__c);
    }

    @IsTest static void unusualHoursBoundariesAndRangeShapesAreExact() {
        Time start = Time.newInstance(22, 0, 0, 0);
        Time endAt = Time.newInstance(6, 0, 0, 0);
        System.assertEquals(false, OrgMonitorChangeProcessor.isUnusualTime(
            Time.newInstance(21, 59, 0, 0), start, endAt));
        System.assertEquals(true, OrgMonitorChangeProcessor.isUnusualTime(start, start, endAt));
        System.assertEquals(true, OrgMonitorChangeProcessor.isUnusualTime(
            Time.newInstance(0, 0, 0, 0), start, endAt));
        System.assertEquals(true, OrgMonitorChangeProcessor.isUnusualTime(
            Time.newInstance(5, 59, 0, 0), start, endAt));
        System.assertEquals(false, OrgMonitorChangeProcessor.isUnusualTime(endAt, start, endAt));
        System.assertEquals(true, OrgMonitorChangeProcessor.isUnusualTime(
            Time.newInstance(10, 0, 0, 0), Time.newInstance(9, 0, 0, 0),
            Time.newInstance(17, 0, 0, 0)), 'Same-day ranges must be supported.');
        System.assertEquals(false, OrgMonitorChangeProcessor.isUnusualTime(
            Time.newInstance(18, 0, 0, 0), Time.newInstance(9, 0, 0, 0),
            Time.newInstance(17, 0, 0, 0)));
        System.assertEquals(false, OrgMonitorChangeProcessor.isUnusualTime(start, start, start));
    }

    @IsTest static void organizationTimeConversionHonoursDstAndOtherTimezones() {
        Time sydStandard = OrgMonitorChangeProcessor.toOrganizationTime(
            Datetime.newInstanceGMT(2026, 7, 1, 12, 0, 0), TimeZone.getTimeZone('Australia/Sydney'));
        Time sydDaylight = OrgMonitorChangeProcessor.toOrganizationTime(
            Datetime.newInstanceGMT(2026, 1, 1, 12, 0, 0), TimeZone.getTimeZone('Australia/Sydney'));
        Time newYork = OrgMonitorChangeProcessor.toOrganizationTime(
            Datetime.newInstanceGMT(2026, 1, 1, 5, 0, 0), TimeZone.getTimeZone('America/New_York'));
        System.assertEquals(Time.newInstance(22, 0, 0, 0), sydStandard);
        System.assertEquals(Time.newInstance(23, 0, 0, 0), sydDaylight);
        System.assertEquals(Time.newInstance(0, 0, 0, 0), newYork);
    }

    @IsTest static void storesUnusualHoursAndFormulaUsesWindowReasonCode() {
        // 12:30 UTC is 11:30 PM AEDT on 1 January.
        Datetime changedAt = Datetime.newInstanceGMT(2026, 1, 1, 12, 30, 0);
        OrgMonitorChangeProcessor processor = new OrgMonitorChangeProcessor();
        FakeLoginDataProvider provider = new FakeLoginDataProvider();
        provider.historyReadable = false;
        processor.loginDataProvider = provider;
        processor.process(new List<SObject>{ audit('0Ym000000000025', 'known', 'Setup',
            'Changed', changedAt, null) }, config(new List<OrgMonitorChangeRunConfig.Rule>{
                rule('known', null, 'LOW', false) }, false, false, null), 'OM-ODD-HOURS');
        Change_Log__c row = [SELECT Unusual_Hours__c, Change_Timing_Indicator__c,
            Compliance_Reason_Code__c FROM Change_Log__c
            WHERE Run_Correlation_Id__c = 'OM-ODD-HOURS'];
        System.assertEquals(true, row.Unusual_Hours__c);
        System.assertEquals('NO_DEPLOYMENT_WINDOW', row.Compliance_Reason_Code__c);
        System.assertEquals('🌙 Odd hours • Outside deployment window',
            row.Change_Timing_Indicator__c);
    }

    private static LoginHistory loginHistory(Datetime loginTime, String status, String sourceIp) {
        return loginHistory(null, loginTime, status, sourceIp, null, null);
    }

    private static LoginHistory loginHistory(Id userId, Datetime loginTime, String status,
            String sourceIp, String forwardedForIp, Id geoId) {
        return (LoginHistory)JSON.deserialize(JSON.serialize(new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'LoginHistory' },
            'UserId' => userId, 'LoginTime' => loginTime, 'Status' => status,
            'SourceIp' => sourceIp, 'ForwardedForIp' => forwardedForIp, 'LoginGeoId' => geoId
        }), LoginHistory.class);
    }

    private static LoginGeo loginGeo(Id geoId, String city, String state, String country,
            String postalCode) {
        return (LoginGeo)JSON.deserialize(JSON.serialize(new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'LoginGeo' },
            'Id' => geoId, 'City' => city, 'Subdivision' => state,
            'Country' => country, 'PostalCode' => postalCode
        }), LoginGeo.class);
    }
}