import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import saveAppSetup      from '@salesforce/apex/GovernanceSetupController.saveAppSetup';
import scheduleCompliance from '@salesforce/apex/GovernanceSetupController.scheduleCompliance';
import getWizardState from '@salesforce/apex/GovernanceSetupController.getWizardState';
import saveProviderDecision from '@salesforce/apex/GovernanceSetupController.saveProviderDecision';

const STEPS = [
    {
        number: 1,
        label: 'Welcome',
        configStatus: 'Configured',
        helpTitle: 'About This Setup',
        helpItems: [
            'Core monitoring takes only a few minutes to configure',
            'Configure CI/CD user filtering',
            'Activate hourly compliance monitoring',
        ],
    },
    {
        number: 2,
        label: 'App Setup',
        configStatus: 'Not configured',
        helpTitle: 'What we\'ll configure',
        helpItems: [
            'Identify deployment & CI/CD users',
            'Set deployment window approval users',
            'Choose the initial compliance lookback window',
        ],
    },
    { number: 3, label: 'Slack Notifications', shortLabel: 'Slack', configStatus: 'Not started', helpTitle: 'Slack notifications', helpItems: ['Optional Slack connection', 'Select and test a destination channel'] },
    { number: 4, label: 'Teams Notifications', shortLabel: 'Teams', configStatus: 'Not started', helpTitle: 'Microsoft Teams notifications', helpItems: ['Optional Microsoft Teams connection', 'Select and test a Team and channel'] },
    {
        number: 5,
        label: 'Review',
        configStatus: 'Not configured',
        helpTitle: 'Almost done',
        helpItems: [
            'Review your configuration',
            'Save settings to ChangeLogRuntime__c',
            'Activate hourly compliance scheduling',
        ],
    },
];

const NEXT_LABELS = ['Next', 'Save and Continue', 'Save and Continue', 'Save and Continue', 'Save & Activate'];

export default class GovernanceSetupWizard extends LightningElement {
    @track currentStepIndex = 0;
    @track isSaving         = false;
    @track isComplete       = false;
    @track isInitialLoading = true;
    @track loadError = '';

    // Form state — owned by parent, passed down to stepAppSetup
    @track deploymentUsers  = [];
    @track enableApproval   = false;
    @track approvalUsers    = [];
    @track initialRunWindow = '';
    @track unusualHoursStart = '22:00';
    @track unusualHoursEnd = '06:00';
    @track skipDeploymentWindowsForSandbox = false;
    @track isSandbox = false;
    @track slackEnabled = false;
    @track microsoftEnabled = false;
    @track slackSetupComplete = false;
    @track microsoftSetupComplete = false;
    @track slackIdentity = '';
    @track microsoftIdentity = '';

    @track steps = STEPS.map(s => ({ ...s }));

    connectedCallback() { this._hydrate(); }

    // ── Computed ──────────────────────────────────────────────────────────────

    get totalSteps() {
        return this.steps.length;
    }
    get canRenderWizard() { return !this.isInitialLoading && !this.loadError; }

    get currentStepData() {
        return this.steps[this.currentStepIndex] || this.steps[0];
    }

    get nextButtonLabel() {
        return NEXT_LABELS[this.currentStepIndex] || 'Next';
    }

    get isStep0() { return this.currentStepIndex === 0; }
    get isStep1() { return this.currentStepIndex === 1; }
    get isStep2() { return this.currentStepIndex === 2; }
    get isStep3() { return this.currentStepIndex === 3; }
    get isStep4() { return this.currentStepIndex === 4; }
    get completedSteps() { return this.steps.filter(step => ['Configured', 'Skipped', 'Complete'].includes(step.configStatus)).length; }

    get deploymentUsersSummary() {
        return this.deploymentUsers.map(u => u.label).join(', ') || 'None';
    }

    get approvalSummary() {
        return this.enableApproval ? 'Enabled' : 'Disabled';
    }

    // ── Form field handlers (from stepAppSetup) ───────────────────────────────

    handleDeploymentUsersChange(event) {
        this.deploymentUsers = event.detail.value;
    }

    handleEnableApprovalChange(event) {
        this.enableApproval = event.detail.value;
        if (!this.enableApproval) {
            this.approvalUsers = [];
        }
    }

    handleApprovalUsersChange(event) {
        this.approvalUsers = event.detail.value;
    }

    handleRunWindowChange(event) {
        this.initialRunWindow = event.detail.value;
    }

    handleUnusualHoursChange(event) {
        this.unusualHoursStart = event.detail.start;
        this.unusualHoursEnd = event.detail.end;
    }

    handleSandboxSkipChange(event) {
        this.skipDeploymentWindowsForSandbox = event.detail.value;
    }

    async handleProviderChange(event) {
        if (event.detail.name === 'slack') this.slackEnabled = event.detail.value;
        if (event.detail.name === 'microsoft') this.microsoftEnabled = event.detail.value;
        try { await saveProviderDecision({ provider: event.detail.name, enabled: event.detail.value, stage: event.detail.name === 'slack' ? 3 : 4 }); }
        catch (error) { this._showError(error); }
    }
    handleSetupStatusChange(event) {
        const { provider, complete, identity } = event.detail;
        if (provider === 'slack') { this.slackSetupComplete = complete; this.slackIdentity = identity || ''; }
        if (provider === 'microsoft') { this.microsoftSetupComplete = complete; this.microsoftIdentity = identity || ''; }
    }

    // ── Navigation ────────────────────────────────────────────────────────────

    handleStepSelect(event) {
        const { stepIndex } = event.detail;
        if (stepIndex < this.currentStepIndex) {
            this.currentStepIndex = stepIndex;
            this._focusMain();
        }
    }

    handleBack() {
        if (this.currentStepIndex > 0) {
            this.currentStepIndex -= 1;
            this._focusMain();
        }
    }

    async handleNext() {
        if (this.currentStepIndex === 1) {
            // Step 2 → validate and save to custom setting + queue
            if (!this._validateAppSetup()) return;
            await this._saveSetup();
        } else if (this.currentStepIndex === 2) {
            if (this.slackEnabled && !this.slackSetupComplete) { this._showValidation('Complete Slack authorization, channel selection, and a successful test message before continuing.'); return; }
            await saveProviderDecision({ provider: 'slack', enabled: this.slackEnabled, stage: 3 });
            this._markStepStatus(2, this.slackEnabled ? 'Configured' : 'Skipped'); this._advanceStep();
        } else if (this.currentStepIndex === 3) {
            if (this.microsoftEnabled && !this.microsoftSetupComplete) { this._showValidation('Complete Microsoft Teams authorization, destination selection, and a successful test message before continuing.'); return; }
            await saveProviderDecision({ provider: 'microsoft', enabled: this.microsoftEnabled, stage: 4 });
            this._markStepStatus(3, this.microsoftEnabled ? 'Configured' : 'Skipped'); this._advanceStep();
        } else if (this.currentStepIndex === 4) {
            await this._activateScheduler();
        } else {
            // Step 1 (Welcome) → just advance
            this._advanceStep();
        }
    }

    // ── Private: Apex calls ───────────────────────────────────────────────────

    _validateAppSetup() {
        const stepCmp = this.template.querySelector('c-step-app-setup');
        return stepCmp ? stepCmp.validate() : true;
    }

    async _saveSetup() {
        this.isSaving = true;
        try {
            const userIds = this.deploymentUsers.map(u => u.id).join(',');
            const approvalIds = this.approvalUsers.map(u => u.id);
            await saveAppSetup({
                deploymentUserIds : userIds,
                enableApproval    : this.enableApproval,
                approvalUserIds   : approvalIds,
                initialRunWindow  : parseInt(this.initialRunWindow, 10),
                skipDeploymentWindowsForSandbox: this.skipDeploymentWindowsForSandbox,
                unusualHoursStart: this.unusualHoursStart,
                unusualHoursEnd: this.unusualHoursEnd,
            });
            if (this.skipDeploymentWindowsForSandbox) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'App Setup saved',
                    message: 'Deployment Windows will be skipped for nominated deployment users in this sandbox. Changes made by all other users remain subject to normal Deployment Window checks.',
                    variant: 'success',
                }));
            }
            this._markStepConfigured(1);
            this._advanceStep();
        } catch (err) {
            this._showError(err);
        } finally {
            this.isSaving = false;
        }
    }

    async _activateScheduler() {
        this.isSaving = true;
        try {
            await scheduleCompliance();
            this._markStepStatus(4, 'Complete');
            this.isComplete = true;
            requestAnimationFrame(() => this.template.querySelector('.gsw-success-card')?.focus());
        } catch (err) {
            this._showError(err);
        } finally {
            this.isSaving = false;
        }
    }

    // ── Private: helpers ──────────────────────────────────────────────────────

    _advanceStep() {
        if (this.currentStepIndex < this.totalSteps - 1) {
            if (!['Configured', 'Skipped', 'Complete'].includes(this.steps[this.currentStepIndex].configStatus)) this._markStepConfigured(this.currentStepIndex);
            this.currentStepIndex += 1;
            this._focusMain();
        }
    }

    _markStepConfigured(index) {
        this.steps = this.steps.map((step, i) =>
            i === index ? { ...step, configStatus: 'Configured' } : step
        );
    }
    _markStepStatus(index, status) { this.steps = this.steps.map((step, i) => i === index ? { ...step, configStatus: status } : step); }
    _showValidation(message) { this.dispatchEvent(new ShowToastEvent({ title: 'Setup incomplete', message, variant: 'error', mode: 'sticky' })); }
    async _hydrate() {
        this.isInitialLoading = true; this.loadError = '';
        try {
            const state = await getWizardState();
            this.deploymentUsers = state.deploymentUsers || []; this.enableApproval = state.enableApproval === true;
            this.approvalUsers = state.approvalUsers || []; this.initialRunWindow = state.initialRunWindow ? String(state.initialRunWindow) : '';
            this.unusualHoursStart = state.unusualHoursStart || '22:00';
            this.unusualHoursEnd = state.unusualHoursEnd || '06:00';
            this.isSandbox = state.isSandbox === true;
            this.skipDeploymentWindowsForSandbox = this.isSandbox && state.skipDeploymentWindowsForSandbox === true;
            this.slackEnabled = state.slackEnabled === true; this.microsoftEnabled = state.teamsEnabled === true;
            const saved = Math.max(0, Math.min(Number(state.lastSavedStage || 0), 4));
            // Restore durable completion immediately. The provider component also
            // verifies the live principal when it loads, but navigation must not
            // race that asynchronous call or discard a previously successful test.
            this.slackSetupComplete = this.slackEnabled
                && !!state.slackWorkspaceId && !!state.slackChannelId
                && state.slackCredential?.credentialsConfigured === true;
            this.microsoftSetupComplete = this.microsoftEnabled
                && !!state.teamsIdentityId && !!state.teamsTeamId && !!state.teamsChannelId
                && state.teamsCredential?.credentialsConfigured === true;
            this.slackIdentity = state.slackWorkspaceName || ''; this.microsoftIdentity = state.teamsIdentityName || '';
            this.steps = this.steps.map((step, index) => index < saved ? { ...step, configStatus: index === 2 && !this.slackEnabled || index === 3 && !this.microsoftEnabled ? 'Skipped' : 'Configured' } : step);
            this.currentStepIndex = saved;
        } catch (error) { this.loadError = error?.body?.message || 'Unable to load saved Org Monitor setup.'; }
        finally { this.isInitialLoading = false; }
    }
    handleRetryLoad() { this._hydrate(); }
    handleSkipToContent(event) { event.preventDefault(); this._focusMain(); }
    handleReturnToSetup() {
        this.isComplete = false;
        this.currentStepIndex = 1;
        this._focusMain();
    }

    _focusMain() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const main = this.template.querySelector('.gsw-main');
            if (main) main.focus();
        }, 0);
    }

    _showError(err) {
        const message = err?.body?.message || err?.message || 'An unexpected error occurred.';
        this.dispatchEvent(new ShowToastEvent({
            title   : 'Error',
            message,
            variant : 'error',
            mode    : 'sticky',
        }));
    }
}