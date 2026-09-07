import { api, LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import listWindows from '@salesforce/apex/DeploymentWindowController.listWindows';
import getWindow from '@salesforce/apex/DeploymentWindowController.getWindow';
import saveWindowFromWorkspace from '@salesforce/apex/DeploymentWindowController.saveWindowFromWorkspace';
import transitionWindow from '@salesforce/apex/DeploymentWindowController.transition';
import searchUsers from '@salesforce/apex/DeploymentWindowController.searchUsers';
import getCapabilities from '@salesforce/apex/DeploymentWindowController.getCapabilities';

const PAGE_SIZE = 50;
const STATUS_LABELS = { Active: 'Open', Draft: 'Scheduled' };
const ROLE_OPTIONS = ['CI/CD User', 'Administrator', 'Developer', 'Release Manager', 'Data Migration', 'Other']
    .map(value => ({ label: value, value }));

export default class DeploymentWindowsWorkspace extends NavigationMixin(LightningElement) {
    @api recordId;
    @track records = [];
    @track capabilities = {};
    @track currentWindow;
    @track nextWindow;
    @track detail;
    @track form = this.emptyForm();
    @track ownerOptions = [];
    @track requesterOptions = [];
    @track authorisedUserOptions = [];
    authorisedUserSearch = '';
    activeView = 'CURRENT';
    view = 'list';
    totalCount = 0;
    loading = true;
    saving = false;
    errorMessage = '';
    formError = '';
    modal = '';
    transitionAction = '';
    transitionLabel = '';
    _returnFocus;
    _searchTimer;

    connectedCallback() { if (this.recordId) this.loadRecordPage(); else this.load(); }
    disconnectedCallback() { if (this._searchTimer) clearTimeout(this._searchTimer); }
    get isListView() { return this.view === 'list'; }
    get isDetailView() { return this.view === 'detail' && !!this.detail; }
    get isCurrent() { return this.activeView === 'CURRENT'; }
    get isPast() { return this.activeView === 'PAST'; }
    get currentTabClass() { return this.isCurrent ? 'active' : ''; }
    get pastTabClass() { return this.isPast ? 'active' : ''; }
    get hasRecords() { return this.records.length > 0; }
    get listTitle() { return this.isCurrent ? 'Current and upcoming deployment windows' : 'Past deployment windows'; }
    get recordCountLabel() { return `${this.totalCount} deployment window${this.totalCount === 1 ? '' : 's'}`; }
    get emptyTitle() { return this.isCurrent ? 'No current or upcoming deployment windows' : 'No past deployment windows'; }
    get emptyMessage() { return this.isCurrent ? 'Create a deployment window to define an authorised Salesforce release period.' : 'Completed and cancelled deployment windows will appear here.'; }
    get currentWindowLabel() { return this.currentWindow ? 'Open now' : 'No open window'; }
    get currentWindowReference() { return this.currentWindow ? `${this.currentWindow.name} · ${this.currentWindow.ticketReference || ''}` : ''; }
    get modalOpen() { return !!this.modal; }
    get isFormModal() { return this.modal === 'form'; }
    get isConfirmModal() { return this.modal === 'confirm'; }
    get modalTitle() { return this.form.recordId ? 'Edit Deployment Window' : 'New Deployment Window'; }
    get formStatusLabel() { return this.form.recordId ? this.statusLabel(this.detail?.storedStatus) : 'Scheduled'; }
    get formApprovedBy() { return this.detail?.approvedByName || ''; }
    get hasMoreActions() { return !!(this.detail?.canActivate || this.detail?.canCancel); }
    get runsheetTitle() { return `${this.detail?.ticketReference || this.detail?.name || ''} — Deployment Runsheet`; }
    get approvalLabel() { if (this.detail?.approvedByName) return `Approved by ${this.detail.approvedByName}`; return this.detail?.status === 'Submitted for Approval' ? 'Awaiting approval' : 'Approval not recorded'; }
    get approvalClass() { return this.detail?.approvedByName ? 'approval approved' : 'approval pending'; }
    get roleOptions() { return ROLE_OPTIONS; }
    get hasAuthorisedUsers() { return (this.detail?.authorisedUsers || []).length > 0; }
    get authorisedUsersInvalid() { return this.formError?.toLowerCase().includes('authorised') || false; }
    get authorisedResultsExpanded() { return this.authorisedUserOptions.length > 0; }

    emptyForm() {
        const start = new Date();
        start.setSeconds(0, 0);
        const end = new Date(start.getTime() + 60 * 60 * 1000);
        const startParts = this.localDateTimeParts(start);
        const endParts = this.localDateTimeParts(end);
        return { recordId: null, startDate: startParts.date, startTime: startParts.time,
            endDate: endParts.date, endTime: endParts.time, ticketReference: '',
            description: '', releaseRunsheetUrl: '', ownerId: null, ownerName: '',
            requestedById: null, requestedByName: '', authorisedUsers: [] };
    }
    localDateTimeParts(value) {
        const pad = number => `${number}`.padStart(2, '0');
        return {
            date: `${value.getFullYear()}-${pad(value.getMonth() + 1)}-${pad(value.getDate())}`,
            time: `${pad(value.getHours())}:${pad(value.getMinutes())}:00.000`
        };
    }
    statusLabel(status) { return STATUS_LABELS[status] || status || '';
    }
    decorate(row) { const statusLabel = this.statusLabel(row.status); return { ...row, statusLabel, statusClass: `status-pill${statusLabel === 'Open' ? ' open' : ''}` }; }
    async loadRecordPage() {
        this.loading = true; this.errorMessage = '';
        try {
            const [capabilities, record] = await Promise.all([getCapabilities(), getWindow({ recordId: this.recordId })]);
            this.capabilities = capabilities || {};
            this.detail = this.decorate(record);
            this.view = 'detail';
        } catch (error) { this.errorMessage = this.message(error, 'Deployment window could not be loaded.'); }
        finally { this.loading = false; }
    }

    async load() {
        this.loading = true; this.errorMessage = '';
        try {
            const result = await listWindows({ viewName: this.activeView, pageNumber: 1, pageSize: PAGE_SIZE });
            this.capabilities = result.capabilities || {};
            this.records = await Promise.all((result.records || []).map(async row => ({
                ...this.decorate(row),
                recordUrl: await this[NavigationMixin.GenerateUrl](this.recordPageReference(row.id))
            })));
            this.currentWindow = result.currentWindow ? this.decorate(result.currentWindow) : null;
            this.nextWindow = result.nextWindow ? this.decorate(result.nextWindow) : null;
            this.totalCount = result.totalCount || 0;
        } catch (error) { this.errorMessage = this.message(error, 'Deployment windows could not be loaded.'); }
        finally { this.loading = false; }
    }

    switchView(event) { const next = event.currentTarget.dataset.view; if (next === this.activeView) return; this.activeView = next; this.load(); }
    recordPageReference(recordId) { return { type: 'standard__recordPage', attributes: { recordId, actionName: 'view' } }; }
    navigateToRecord(event) { event?.preventDefault?.(); this[NavigationMixin.Navigate](this.recordPageReference(event.currentTarget.dataset.id)); }
    openNew(event) { this._returnFocus = event.target; this.detail = null; this.form = { ...this.emptyForm(), authorisedUsers: this.copyAuthorisedUsers(this.capabilities.defaultAuthorisedUsers) }; this.ownerOptions = []; this.requesterOptions = []; this.authorisedUserOptions = []; this.openModal('form'); }
    async editFromDetail(event) { this._returnFocus = event.target; this.form = this.formFrom(this.detail); this.openModal('form'); }
    formFrom(row) { const start = this.splitDateTime(row.startDateTime); const end = this.splitDateTime(row.endDateTime); return { recordId: row.id, startDate: start.date, startTime: start.time, endDate: end.date, endTime: end.time, ticketReference: row.ticketReference || '', description: row.description || '', releaseRunsheetUrl: row.releaseRunsheetUrl || '', ownerId: row.ownerId, ownerName: row.ownerName || '', requestedById: row.requestedById, requestedByName: row.requestedByName || '', authorisedUsers: this.copyAuthorisedUsers(row.authorisedUsers) }; }
    copyAuthorisedUsers(values) { return (values || []).map(value => ({ ...value, notes: value.notes || '', removeLabel: `Remove ${value.userName}` })); }
    splitDateTime(value) { if (!value) return { date: '', time: '' }; const date = new Date(value); const pad = number => `${number}`.padStart(2, '0'); return { date: `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`, time: `${pad(date.getHours())}:${pad(date.getMinutes())}:00.000` }; }
    combineDateTime(date, time) { if (!date || !time) return null; return new Date(`${date}T${time.substring(0, 5)}:00`).toISOString(); }

    openModal(name) { this.modal = name; this.formError = ''; requestAnimationFrame(() => this.template.querySelector('.modal-heading')?.focus()); }
    closeModal() { this.modal = ''; this.formError = ''; requestAnimationFrame(() => this._returnFocus?.focus?.()); }
    handleModalKeydown(event) {
        if (event.key === 'Escape' && !this.saving) { event.preventDefault(); this.closeModal(); return; }
        if (event.key !== 'Tab') return;
        const focusable = [...this.template.querySelectorAll(
            'button:not([disabled]), a[href], lightning-button:not([disabled]), lightning-button-icon:not([disabled]), lightning-input:not([disabled]), lightning-textarea:not([disabled]), lightning-combobox:not([disabled]), lightning-button-menu:not([disabled]), [tabindex="0"]'
        )].filter(element => !element.closest('[hidden]'));
        if (!focusable.length) return;
        const first = focusable[0]; const last = focusable[focusable.length - 1];
        if (event.shiftKey && (event.target === first || event.target === this.template.querySelector('.modal-heading'))) {
            event.preventDefault(); last.focus();
        } else if (!event.shiftKey && event.target === last) { event.preventDefault(); first.focus(); }
    }
    handleFormInput(event) { this.form = { ...this.form, [event.target.dataset.field]: event.detail?.value ?? event.target.value }; event.target.setCustomValidity(''); }
    handleUserSearch(event) {
        const type = event.target.dataset.userType; const term = event.target.value; const idField = type === 'owner' ? 'ownerId' : 'requestedById'; const nameField = type === 'owner' ? 'ownerName' : 'requestedByName';
        this.form = { ...this.form, [nameField]: term, [idField]: null };
        if (this._searchTimer) clearTimeout(this._searchTimer);
        this._searchTimer = setTimeout(async () => { const optionsField = type === 'owner' ? 'ownerOptions' : 'requesterOptions'; if (!term || term.trim().length < 2) { this[optionsField] = []; return; } try { this[optionsField] = await searchUsers({ searchTerm: term }); } catch (error) { this.formError = this.message(error, 'Users could not be searched.'); } }, 250);
    }
    selectUser(event) { const type = event.currentTarget.dataset.userType; const optionsField = type === 'owner' ? 'ownerOptions' : 'requesterOptions'; const option = this[optionsField].find(item => item.id === event.currentTarget.dataset.id); if (!option) return; this.form = { ...this.form, [type === 'owner' ? 'ownerId' : 'requestedById']: option.id, [type === 'owner' ? 'ownerName' : 'requestedByName']: option.label }; this[optionsField] = []; }

    handleAuthorisedUserSearch(event) {
        const term = event.target.value; this.authorisedUserSearch = term;
        if (this._searchTimer) clearTimeout(this._searchTimer);
        this._searchTimer = setTimeout(async () => {
            if (!term || term.trim().length < 2) { this.authorisedUserOptions = []; return; }
            try { this.authorisedUserOptions = await searchUsers({ searchTerm: term }); }
            catch (error) { this.formError = this.message(error, 'Users could not be searched.'); }
        }, 250);
    }
    handleLookupKeydown(event) {
        if (event.key === 'ArrowDown' && this.authorisedUserOptions.length) {
            event.preventDefault(); this.template.querySelector('[data-authorised-option]')?.focus();
        } else if (event.key === 'Escape') { this.authorisedUserOptions = []; }
    }
    handleLookupOptionKeydown(event) {
        const options = [...this.template.querySelectorAll('[data-authorised-option]')];
        const index = options.indexOf(event.currentTarget);
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault(); const direction = event.key === 'ArrowDown' ? 1 : -1;
            options[(index + direction + options.length) % options.length]?.focus();
        } else if (event.key === 'Escape') {
            event.preventDefault(); this.authorisedUserOptions = [];
            requestAnimationFrame(() => this.template.querySelector('[data-authorised-search]')?.focus());
        }
    }
    addAuthorisedUser(event) {
        const option = this.authorisedUserOptions.find(item => item.id === event.currentTarget.dataset.id);
        if (!option) return;
        if ((this.form.authorisedUsers || []).some(item => item.userId === option.id)) {
            this.formError = 'The same authorised deployment user cannot be added more than once.'; return;
        }
        this.form = { ...this.form, authorisedUsers: [...(this.form.authorisedUsers || []), {
            recordId: null, userId: option.id, userName: option.label, deploymentRole: '', notes: '', removeLabel: `Remove ${option.label}`
        }] };
        this.authorisedUserOptions = []; this.authorisedUserSearch = '';
        this.formError = '';
        requestAnimationFrame(() => this.template.querySelector(`lightning-combobox[data-user-id="${option.id}"]`)?.focus());
    }
    updateAuthorisedUser(event) {
        const userId = event.target.dataset.userId; const field = event.target.dataset.field;
        this.form = { ...this.form, authorisedUsers: this.form.authorisedUsers.map(item =>
            item.userId === userId ? { ...item, [field]: event.detail?.value ?? event.target.value } : item) };
    }
    removeAuthorisedUser(event) {
        const userId = event.currentTarget.dataset.userId;
        this.form = { ...this.form, authorisedUsers: this.form.authorisedUsers.filter(item => item.userId !== userId) };
        requestAnimationFrame(() => this.template.querySelector('[data-authorised-search]')?.focus());
    }

    async save(event) {
        event?.preventDefault?.(); this.formError = '';
        const inputs = [...this.template.querySelectorAll('[data-form-input]')];
        const submitted = { ...this.form };
        let valid = true;
        inputs.forEach(input => {
            submitted[input.dataset.field] = input.value;
            if (!input.reportValidity()) valid = false;
        });
        this.form = submitted;
        const startDateTime = this.combineDateTime(submitted.startDate, submitted.startTime);
        const endDateTime = this.combineDateTime(submitted.endDate, submitted.endTime);
        if (startDateTime && endDateTime && new Date(endDateTime) <= new Date(startDateTime)) { this.formError = 'End Date and Time must be later than Start Date and Time.'; valid = false; }
        if (submitted.releaseRunsheetUrl && !this.validHttps(submitted.releaseRunsheetUrl)) { this.formError = 'Release Runsheet must be a secure HTTPS URL.'; valid = false; }
        if (!submitted.authorisedUsers?.length) { this.formError = 'Add at least one Authorised Deployment User.'; valid = false; }
        else if (submitted.authorisedUsers.some(item => !item.deploymentRole)) { this.formError = 'Select a deployment role for every authorised user.'; valid = false; }
        if (!valid) { this.template.querySelector('[data-error-summary]')?.focus(); return; }
        this.saving = true;
        try {
            const request = { recordId: submitted.recordId, startDateTime, endDateTime, ticketReference: submitted.ticketReference, description: submitted.description, releaseRunsheetUrl: submitted.releaseRunsheetUrl, ownerId: submitted.ownerId, requestedById: submitted.requestedById, authorisedUsers: submitted.authorisedUsers.map(({ recordId, userId, deploymentRole, notes }) => ({ recordId, userId, deploymentRole, notes })) };
            const id = await saveWindowFromWorkspace({ requestJson: JSON.stringify(request), startDateTimeIso: startDateTime, endDateTimeIso: endDateTime }); this.closeModal(); this.toast('Success', this.form.recordId ? 'Deployment window updated.' : 'Deployment window created.', 'success'); this[NavigationMixin.Navigate](this.recordPageReference(id));
        } catch (error) { this.formError = this.message(error, 'Deployment window could not be saved.'); requestAnimationFrame(() => this.template.querySelector('[data-error-summary]')?.focus()); }
        finally { this.saving = false; }
    }

    confirmFromDetail(event) { this.openConfirm(event.currentTarget.dataset.action); }
    handleMoreAction(event) { this.openConfirm(event.detail.value); }
    openConfirm(action) { const labels = { activate: 'Activate Deployment Window', submit: 'Submit for Approval', close: 'Close Deployment Window', cancel: 'Cancel Deployment Window', approve: 'Approve Deployment Window', reject: 'Reject Deployment Window' }; this.transitionAction = action.toUpperCase(); this.transitionLabel = labels[action]; this.openModal('confirm'); }
    async confirmTransition() { this.saving = true; try { this.detail = this.decorate(await transitionWindow({ recordId: this.detail.id, actionName: this.transitionAction })); this.closeModal(); this.toast('Success', `${this.detail.name} is now ${this.detail.statusLabel}.`, 'success'); await this.load(); } catch (error) { this.formError = this.message(error, 'The deployment window status could not be changed.'); } finally { this.saving = false; } }
    validHttps(value) { try { const url = new URL(value); return url.protocol === 'https:' && !!url.hostname; } catch { return false; } }
    message(error, fallback) { return error?.body?.message || error?.message || fallback; }
    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
}