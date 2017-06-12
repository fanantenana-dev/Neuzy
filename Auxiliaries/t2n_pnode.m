function prop = t2n_pnode(tree,neuron,node)
% This function returns all properties (mechanisms and point processes)
% that have been set at a specific node.
% INPUT
% tree      TREES toolbox tree structure or cell array of tree structures
% neuron    t2n neuron structure (see documentation)
% node      index (or indices if multiple trees) to the node of interest in the tree
%
% OUTPUT
% prop      structure or cell array of structures with all properties at 
%           the specified node of the tree(s)


if isstruct(tree)
    tree = {tree};
end
if isstruct(neuron)
    neuron = {neuron};
end
if numel(node) == 1
    node = repmat(node,numel(tree),1);
end
prop = cell(numel(neuron),numel(tree));
[tree,~,neuron,thesetrees] = t2n_checkinput(tree,[],neuron);
for n = 1:numel(neuron)
    for tt = 1:numel(thesetrees{n})
        t = thesetrees{n}(tt);
        if isfield(neuron{n},'mech')
            if isfield(neuron{n}.mech{tt},'all')   % variable was set in all nodes
                prop{n,t} = neuron{n}.mech{tt}.all;
            end
            regions = intersect(tree{t}.rnames{tree{t}.R(node(t))},fieldnames(neuron{n}.mech{tt}));
            if ~isempty(regions)
                if ~isempty(prop{n,t})
                    prop{n,t} = t2n_catStruct(prop{n,t},neuron{n}.mech{tt}.(regions{1}));
                else
                    prop{n,t} = neuron{n}.mech{tt}.(regions{1});
                end
            end
            if isfield(neuron{n}.mech{tt},'range')
                mechanisms = fieldnames(neuron{n}.mech{tt}.range);
                for m = 1:numel(mechanisms)
                    vars = fieldnames(neuron{n}.mech{tt}.range.(mechanisms{m}));
                    for v = 1:numel(vars)
                        if ~isnan(neuron{n}.mech{tt}.range.(mechanisms{m}).vars{v}(node(t)))
                            prop{n,t}.mechanisms{m}.vars{v} = neuron{n}.mech{tt}.range.(mechanisms{m}).vars{v}(node(t));
                        end
                    end
                end
            end
        end
        if isfield(neuron{n},'pp')
            pps = fieldnames(neuron{n}.pp{tt});
            for p = 1:numel(pps)
                if any(neuron{n}.pp{tt}.(pps{p}).node==node(t))
                    prop{n,t}.(pps{t}) = rmfield(neuron{n}.pp{tt}.(pps{p}),'node');
                end
            end
        end
    end
end
if numel(tree) == 1 && numel(neuron) == 1
    prop = prop{1};
end