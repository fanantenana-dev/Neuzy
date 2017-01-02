function [ thesetrees,usestreesof ] = t2n_checkinput(neuron,tree)
%UNTITLED2 Summary of this function goes here
%   Detailed explanation goes here

thesetrees = cell(numel(neuron),1);
usestreesof = zeros(numel(neuron),1);
flag = false;
bool = cellfun(@(y) isfield(y,'tree'),neuron);
if all(cellfun(@(y) ischar(y.tree),neuron(bool))) % no trees defined (only due to t2n_as function). make bool = 0
    bool(:) = 0;
end
nempty = cellfun(@isempty,neuron);
if any(nempty)
    error('The defined simulation #%d is empty, please check\n',find(nempty))
end
switch sum(bool)
    case 1   % use that treeids defined in that one simulation
        if isnumeric(neuron{bool}.tree)
            thesetrees = repmat({unique(neuron{bool}.tree)},numel(neuron),1);
            usestreesof = repmat(find(bool),numel(neuron),1);
        else
            x = getref(1,neuron,'tree');
            if isempty(x) % means it refers to itself (maybe due to usage of t2n_as)..use normal trees..
                thesetrees = repmat({1:numel(tree)},numel(neuron),1);
                usestreesof = ones(numel(neuron),1);
                for n = 1:numel(neuron)
                    neuron{n}.tree = thesetrees{n};
                end
            else
                n = find(bool);
                flag = true;
            end
        end
    case 0      % if no trees are given, use trees that are given to t2n in their order...
        thesetrees = repmat({1:numel(tree)},numel(neuron),1);
        usestreesof = ones(numel(neuron),1);
        for n = 1:numel(neuron)
            neuron{n}.tree = thesetrees{n};
        end
    case numel(neuron)
        for n = 1:numel(neuron)
            x = getref(n,neuron,'tree');
            if ~isnan(x)
                thesetrees{n} = unique(neuron{x}.tree);
                usestreesof(n) = x;
            elseif isempty(x)
                thesetrees{n} = 1:numel(tree);%repmat({1:numel(tree)},numel(neuron),1);
                usestreesof(n) = 1;%ones(numel(neuron),1);
                %                 for n = 1:numel(neuron)
                neuron{n}.tree = thesetrees{n};
                %                 end
            else
                flag = true;
                break
            end
        end
    otherwise  % if more than one are given, t2n cannot know which trees you want
        n = find(bool);
        flag = true;
end
if flag
    error('Error in neuron{%d}.tree, please check\n',n)
end

end

