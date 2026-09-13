	return false;
}

function pkgStatus(pkg, vop, ver, info)
{
	info.errors = info.errors || [];
	info.install = info.install || [];

	if (isPkgInstalled(pkg)) {
		if (vop && !versionSatisfied(pkg.version, ver, vop)) {
			let repl = null;

			(packages.available.providers[pkg.name] || []).forEach(function(p) {
				if (!repl && versionSatisfied(p.version, ver, vop))
					repl = p;
			});

			if (repl) {
				info.install.push(repl);
				return E('span', {
					'class': 'label',
					'data-tooltip': _('Requires update to %h %h')
						.format(repl.name, repl.version)
				}, _('Needs upgrade'));
			}

			info.errors.push(_('The installed version of package <em>%h</em> is not compatible, require %s while %s is installed.').format(pkg.name, truncateVersion(ver, vop), truncateVersion(pkg.version)));

			return E('span', {
				'class': 'label warning',
				'data-tooltip': _('Require version %h %h,\ninstalled %h')
					.format(vop, ver, pkg.version)
			}, _('Version incompatible'));
		}

		return E('span', { 'class': 'label notice' }, _('Installed'));
	}
	else if (!pkg.missing) {
		if (!vop || versionSatisfied(pkg.version, ver, vop)) {
			info.install.push(pkg);
			return E('span', { 'class': 'label' }, _('Not installed'));
		}

		info.errors.push(_('The repository version of package <em>%h</em> is not compatible, require %s but only %s is available.')
				.format(pkg.name, truncateVersion(ver, vop), truncateVersion(pkg.version)));

		return E('span', {
			'class': 'label warning',
			'data-tooltip': _('Require version %h %h,\ninstalled %h')
				.format(vop, ver, pkg.version)
		}, _('Version incompatible'));
	}
	else {
		info.errors.push(_('Required dependency package <em>%h</em> is not available in any repository.').format(pkg.name));

		return E('span', { 'class': 'label warning' }, _('Not available'));
	}
}

function renderDependencyItem(dep, info, flat)
{
	const li = E('li');
	const vop = dep.version ? dep.version[0] : null;
	const ver = dep.version ? dep.version[1] : null;
	const depends = [];

	for (let i = 0; dep.pkgs && i < dep.pkgs.length; i++) {
		const pkg = packages.installed.pkgs[dep.pkgs[i]] ||
		          packages.available.pkgs[dep.pkgs[i]] ||
		          { name: dep.name };

		if (i > 0)
			li.appendChild(document.createTextNode(' | '));

		let text = pkg.name;

		if (pkg.installsize)
			text += ' (%1024mB)'.format(pkg.installsize);
		else if (pkg.size)
			text += ' (~%1024mB)'.format(pkg.size);

		li.appendChild(E('span', { 'data-tooltip': pkg.description },
			[ text, ' ', pkgStatus(pkg, vop, ver, info) ]));

		(pkg.depends || []).forEach(function(d) {
			if (depends.indexOf(d) === -1)
				depends.push(d);
		});
	}

	if (!li.firstChild)
		li.appendChild(E('span', {},
			[ dep.name, ' ',
			  pkgStatus({ name: dep.name, missing: true }, vop, ver, info) ]));

	if (!flat) {
		const subdeps = renderDependencies(depends, info);
		if (subdeps)
			li.appendChild(subdeps);
	}

	return li;
}
