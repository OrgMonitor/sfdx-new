import { LightningElement, api, track } from 'lwc';

const RUN_WINDOW_OPTIONS = [
    { label: '15 days', value: '15' },
    { label: '30 days', value: '30' },
    { label: '45 days', value: '45' },
];

export default class StepAppSetup extends LightningElement {
    @api deploymentUsers   = [];
    @api enableApproval    = false;
    @api approvalUsers     = [];
    @api initialRunWindow  = '';
    @api unusualHoursStart = '22:00';
    @api unusualHoursEnd = '06:00';
    @api skipDeploymentWindowsForSandbox = false;
    @api isSandbox = false;
    @api slackEnabled = false;
    @api microsoftEnabled = false;

    @track errors = {
        deploymentUsers : null,
        approvalUsers   : null,
        runWindow       : null,
        sandboxSkip     : null,
        unusualHours    : null,
    };

    get runWindowOptions() {
        return RUN_WINDOW_OPTIONS;
    }
    get hasDeploymentError() { return !!this.errors.deploymentUsers; }
    get hasApprovalError() { return !!this.errors.approvalUsers; }
    get hasSandboxSkipError() { return !!this.errors.sandboxSkip; }

    // ── Field handlers ────────────────────────────────────────────────────────

    handleDeploymentUsersChange(event) {
        this.errors = { ...this.errors, deploymentUsers: null };
        this._emit('deploymentuserschange', { value: event.detail.selectedItems });
    }

    handleEnableApprovalChange(event) {
        this._emit('enableapprovalchange', { value: event.target.checked });
    }

    handleApprovalUsersChange(event) {
        this.errors = { ...this.errors, approvalUsers: null };
        this._emit('approvaluserschange', { value: event.detail.selectedItems });
    }

    handleRunWindowChange(event) {
        this.errors = { ...this.errors, runWindow: null };
        this._emit('runwindowchange', { value: event.detail.value });
    }

    handleUnusualStartChange(event) {
        this.errors = { ...this.errors, unusualHours: null };
        this._emit('unusualhourschange', { start: event.detail.value, end: this.unusualHoursEnd });
    }

    handleUnusualEndChange(event) {
        this.errors = { ...this.errors, unusualHours: null };
        this._emit('unusualhourschange', { start: this.unusualHoursStart, end: event.detail.value });
    }

    handleSandboxSkipChange(event) {
        const enabled = event.target.checked;
        if (enabled && (!this.deploymentUsers || this.deploymentUsers.length === 0)) {
            event.target.checked = false;
            this.errors = {
                ...this.errors,
                sandboxSkip: 'Select at least one deployment user before enabling Skip Deployment Windows for Sandbox.',
            };
            this._emit('sandboxskipchange', { value: false });
            return;
        }
        this.errors = { ...this.errors, sandboxSkip: null };
        this._emit('sandboxskipchange', { value: enabled });
    }

    handleProviderChange(event) {
        this._emit('providerchange', event.detail);
    }
    handleSetupStatusChange(event) {
        this._emit('setupstatuschange', event.detail);
    }

    // ── Public validation API (called by parent before advancing) ─────────────

    @api
    validate() {
        const errs = {
            deploymentUsers : null,
            approvalUsers   : null,
            runWindow       : null,
            sandboxSkip     : null,
            unusualHours    : null,
        };
        let valid = true;

        if (!this.deploymentUsers || this.deploymentUsers.length === 0) {
            errs.deploymentUsers = 'Please select at least one deployment user.';
            valid = false;
        }
        if (this.skipDeploymentWindowsForSandbox && (!this.deploymentUsers || this.deploymentUsers.length === 0)) {
            errs.sandboxSkip = 'Select at least one deployment user before enabling Skip Deployment Windows for Sandbox.';
            valid = false;
        }
        if (this.enableApproval && (!this.approvalUsers || this.approvalUsers.length === 0)) {
            errs.approvalUsers = 'Please select at least one approval user.';
            valid = false;
        }
        if (!this.initialRunWindow) {
            errs.runWindow = 'Please select a historical run timeframe.';
            valid = false;
        }
        if (!this.unusualHoursStart || !this.unusualHoursEnd) {
            errs.unusualHours = 'Both unusual-hours values are required.';
            valid = false;
        } else if (this.unusualHoursStart === this.unusualHoursEnd) {
            errs.unusualHours = 'Unusual Hours Start and End must be different.';
            valid = false;
        }

        this.errors = errs;
        if (!valid) {
            requestAnimationFrame(() => {
                if (errs.deploymentUsers) this.template.querySelector('c-user-token-search')?.focus();
                else if (errs.approvalUsers) this.template.querySelectorAll('c-user-token-search')[1]?.focus();
                else this.template.querySelector('lightning-combobox')?.focus();
            });
        }
        return valid;
    }

    // ── Private ───────────────────────────────────────────────────────────────

    _emit(eventName, detail) {
        this.dispatchEvent(new CustomEvent(eventName, { detail, bubbles: false }));
    }
}