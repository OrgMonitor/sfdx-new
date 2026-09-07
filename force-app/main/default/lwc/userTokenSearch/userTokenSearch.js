import { LightningElement, api, track } from 'lwc';
import searchUsers from '@salesforce/apex/GovernanceSetupController.searchUsers';

let idCounter = 0;

export default class UserTokenSearch extends LightningElement {
    @api placeholder = 'Search users or integration accounts...';
    @api label = 'Search users';
    @api invalid = false;

    @track _selectedItems = [];
    @track searchTerm = '';
    @track isDropdownOpen = false;
    @track highlightedIndex = -1;
    @track searchResults = [];
    @track isSearching = false;
    @track searchError = null;
    @track statusMessage = '';

    _dropdownId = `uts-dropdown-${++idCounter}`;
    _debounceTimer = null;
    disconnectedCallback() { clearTimeout(this._debounceTimer); }

    @api
    get selectedItems() {
        return this._selectedItems;
    }
    set selectedItems(value) {
        this._selectedItems = Array.isArray(value) ? [...value] : [];
    }

    get dropdownId() {
        return this._dropdownId;
    }

    get isDropdownOpenStr() {
        return this.isDropdownOpen ? 'true' : 'false';
    }

    get hasSearchTerm() {
        return this.searchTerm.trim().length > 0;
    }

    get inputPlaceholder() {
        return this._selectedItems.length === 0 ? this.placeholder : '';
    }

    get inputAriaLabel() {
        const count = this._selectedItems.length;
        return count > 0
            ? `${this.label}, ${count} item${count !== 1 ? 's' : ''} selected`
            : this.label;
    }

    @api focus() { this.template.querySelector('.uts-input')?.focus(); }

    get displayTokens() {
        return this._selectedItems.map(item => ({
            ...item,
            groupAriaLabel: item.label,
            removeAriaLabel: `Remove ${item.label}`,
        }));
    }

    get filteredItems() {
        const selectedIds = new Set(this._selectedItems.map(i => i.id));
        return this.searchResults
            .filter(r => !selectedIds.has(r.id))
            .map((r, idx) => ({
                ...r,
                optionId: `${this._dropdownId}-option-${idx}`,
                isHighlighted: idx === this.highlightedIndex,
                cssClass: `uts-result-item${idx === this.highlightedIndex ? ' uts-result-item--highlighted' : ''}`,
            }));
    }

    get hasResults() {
        return this.filteredItems.length > 0;
    }

    get activeDescendant() {
        return this.highlightedIndex >= 0 ? `${this._dropdownId}-option-${this.highlightedIndex}` : null;
    }

    handleContainerClick() {
        this.template.querySelector('.uts-input').focus();
    }

    handleInput(event) {
        this.searchTerm = event.target.value;
        this.highlightedIndex = -1;
        this.isDropdownOpen = true;
        this._debouncedSearch(this.searchTerm);
    }

    handleFocus() {
        this.isDropdownOpen = true;
    }

    handleBlur() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.isDropdownOpen = false;
            this.searchTerm = '';
            this.highlightedIndex = -1;
        }, 150);
    }

    handleKeydown(event) {
        const { key } = event;
        const items = this.filteredItems;

        switch (key) {
            case 'ArrowDown':
                event.preventDefault();
                this.isDropdownOpen = true;
                this.highlightedIndex = Math.min(this.highlightedIndex + 1, items.length - 1);
                break;
            case 'ArrowUp':
                event.preventDefault();
                this.highlightedIndex = Math.max(this.highlightedIndex - 1, 0);
                break;
            case 'Enter':
                if (this.highlightedIndex >= 0 && items[this.highlightedIndex]) {
                    event.preventDefault();
                    this._addItem(items[this.highlightedIndex]);
                }
                break;
            case 'Escape':
                this.isDropdownOpen = false;
                this.searchTerm = '';
                this.highlightedIndex = -1;
                break;
            case 'Backspace':
                if (this.searchTerm === '' && this._selectedItems.length > 0) {
                    this._selectedItems = this._selectedItems.slice(0, -1);
                    this._dispatchChange();
                }
                break;
            default:
                break;
        }
    }

    handleSelectItem(event) {
        event.preventDefault();
        const { id, label } = event.currentTarget.dataset;
        this._addItem({ id, label });
    }

    handleRemoveToken(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        const removed = this._selectedItems.find(i => i.id === id);
        this._selectedItems = this._selectedItems.filter(i => i.id !== id);
        this.statusMessage = removed ? `${removed.label} removed.` : 'User removed.';
        this._dispatchChange();
    }

    _debouncedSearch(term) {
        clearTimeout(this._debounceTimer);
        if (!term || term.trim().length < 2) {
            this.searchResults = [];
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._debounceTimer = setTimeout(() => {
            this._callSearch(term.trim());
        }, 300);
    }

    async _callSearch(term) {
        this.isSearching = true;
        this.searchError = null;
        try {
            const results = await searchUsers({ searchTerm: term });
            this.searchResults = results || [];
            const count = this.filteredItems.length;
            this.statusMessage = count ? `${count} user result${count === 1 ? '' : 's'} available. Use the up and down arrow keys to review results.` : 'No matching users found.';
        } catch (err) {
            this.searchError = err?.body?.message || 'Search failed. Please try again.';
            this.searchResults = [];
            this.statusMessage = this.searchError;
        } finally {
            this.isSearching = false;
        }
    }

    _addItem(item) {
        if (!this._selectedItems.find(s => s.id === item.id)) {
            this._selectedItems = [...this._selectedItems, { id: item.id, label: item.label }];
            this.statusMessage = `${item.label} selected.`;
            this._dispatchChange();
        }
        this.searchTerm = '';
        this.searchResults = [];
        this.highlightedIndex = -1;
        this.isDropdownOpen = false;
    }

    _dispatchChange() {
        this.dispatchEvent(new CustomEvent('selectionchange', {
            detail: { selectedItems: [...this._selectedItems] },
        }));
    }
}