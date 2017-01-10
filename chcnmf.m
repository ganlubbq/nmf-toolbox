function [W, H, S, G, cost] = chcnmf(V, num_basis_elems, num_frames, config)
% chcnmf Decompose a matrix V into SGH using Convex hull-CNMF [1] by
% minimizing the Euclidean distance between V and SGH. W = SG is a basis
% matrix, where the columns of G form convex combinations of S, which
% contain the convex hull of the data V, and H is the encoding matrix that
% encodes the input V in terms of the basis W. Unlike NMF, V can have mixed
% sign. The columns of W can be interpreted as cluster centroids (there is 
% a connection to K-means clustering), while H shows the soft membership of
% each data point to the clusters.
%
% Inputs:
%   V: [matrix]
%       m-by-n matrix containing data to be decomposed.
%                 ----------------
%         data    |              |
%       dimension |      V       |
%                 |              |
%                 ----------------
%                  time --->
%   num_basis_elems: [positive scalar]
%       number of basis elements (columns of G/rows of H) for 1 source.
%   num_frames: [positive scalar]
%       number of context frames.
%   config: [structure] (optional)
%       structure containing configuration parameters.
%       config.S_init: [matrix] (default: matrix returned by Matlab's
%           convhull function with input V)
%           initialize m-by-p matrix containing p points belonging to the
%           convex hull of V. 
%       config.G_init: [non-negative 3D tensor] (default: random tensor)
%           initialize time-varying convex combination matrix with a
%           p-by-num_basis_elems-by-num_frames tensor.
%       config.H_init: [non-negative matrix] (default: n indicator vectors
%           of cluster membership using K-means + 0.2)
%           initialize encoding matrix with a num_basis_elems-by-n
%           non-negative matrix.
%       config.G_fixed: [boolean] (default: false)
%           indicate if the time-varying convex combination matrix is fixed
%           during the update equations.
%       config.H_fixed: [boolean] (default: false)
%           indicate if the encoding matrix is fixed during the update
%           equations.
%       config.G_sparsity: [non-negative scalar] (default: 0)
%           sparsity level for the time-varying convex combination matrix.
%       config.H_sparsity: [non-negative scalar] (default: 0)
%           sparsity level for the encoding matrix.
%       config.maxiter: [positive scalar] (default: 100)
%           maximum number of update iterations.
%       config.tolerance: [positive scalar] (default: 1e-3)
%           maximum change in the cost function between iterations before
%           the algorithm is considered to have converged.
%
% Outputs:
%   W: [3D tensor]
%       m-by-num_basis_elems-by-num_frames basis tensor. W = S*G.
%   H: [non-negative matrix]
%       num_basis_elems-by-n non-negative encoding matrix.
%   S: [matrix]
%       m-by-p matrix of p points belonging to the convex hull of V.
%   G: [non-negative 3D tensor]
%       p-by-num_basis_elems-by-num_frames tensor of time-varying convex
%       combinations of the columns of S.
%   cost: [vector]
%       value of the cost function after each iteration.
%
% References:
%   [1] C. Vaz, A. Toutios, and S. Narayanan, "Convex Hull Convolutive
%       Non-negative Matrix Factorization for Uncovering Temporal Patterns
%       in Multivariate Time-Series Data," in Interspeech, San Francisco,
%       CA, 2016.
%
% NMF Toolbox
% Colin Vaz - cvaz@usc.edu
% Signal Analysis and Interpretation Lab (SAIL) - http://sail.usc.edu
% University of Southern California
% 2015

% Check if configuration structure is given.
if nargin < 4
	config = struct;
end

[m, n] = size(V);

% Initialize convex hull points
if ~isfield(config, 'S_init') || isempty(config.S_init)
    % If V is 1D, then convexhull is just max and min points
    if m == 1
        config.S_init = [min(V) max(V)];
    else
        data_cov = cov(V');
        if num_basis_elems >= m
            [eigenvecs, ~] = eig(data_cov);
        else
            [eigenvecs, ~] = eigs(data_cov, num_basis_elems);
        end
        config.S_init = [];
        for e1 = 1 : min(num_basis_elems, m)-1
            for e2 = e1+1 : min(num_basis_elems, m)
                projected_data = V' * [eigenvecs(:, e1) eigenvecs(:, e2)];
                convexhull_idx = convhull(projected_data);
                config.S_init = [config.S_init V(:, convexhull_idx)];
                config.S_init = unique(config.S_init.', 'rows').';  % remove duplicate data points
            end
        end
    end
end
S = config.S_init;
num_points = size(S, 2);

% Initialize convex combination tensor
if ~isfield(config, 'G_init') || isempty(config.G_init)
    config.G_init = rand(num_points, num_basis_elems, num_frames);
%     for t = 2 : num_frames
%         config.G_init(:, :, t) = abs(config.G_init(:, :, t-1) + 0.1 * (2*rand(num_points, num_basis_elems) - 1));
%     end
    norms = zeros(num_basis_elems, num_frames);
    for t = 1 : num_frames
        norms(:, t) = sum(config.G_init(:, :, t), 1)';
        config.G_init(:, :, t) = config.G_init(:, :, t) * diag(1 ./ sum(config.G_init(:, :, t)));
    end
end
G = config.G_init;

% Update switch for convex combination tensor
if ~isfield(config, 'G_fixed')
    config.G_fixed = false;
end

% Sparsity level for convex combination tensor
if ~isfield(config, 'G_sparsity') || isempty(config.G_sparsity)
    config.G_sparsity = 0;
% elseif config.G_sparsity > 0  % Hoyer's sparsity constraint
%     L2s = 1 / (sqrt(m) - (sqrt(m) - 1) * config.G_sparsity);
%     for t = 1 : num_frames
%         for k = 1 : num_basis_elems
%             G(:, k, t) = projfunc(G(:, k, t), 1, L2s, 1);
%         end
%     end
end

% Initialize encoding matrix
if ~isfield(config, 'H_init') || isempty(config.H_init)
%     cluster_idx = kmeans(V.', num_basis_elems);
%     config.H_init = zeros(num_basis_elems, n);
%     for j = 1 : n
%         config.H_init(cluster_idx(j), j) = 1;
%     end
%     config.H_init = config.H_init + 0.2*rand(num_basis_elems, n);
    config.H_init = rand(num_basis_elems, n);
end
H = config.H_init;

% Update switch for encoding matrix
if ~isfield(config, 'H_fixed')
    config.H_fixed = false;
end

% Sparsity level for encoding matrix
% TODO: look into using Hoyer's sparsity constraint
if ~isfield(config, 'H_sparsity') || isempty(config.H_sparsity)
    config.H_sparsity = 0;
% elseif config.H_sparsity > 0  % Hoyer's sparsity constraint
%     L1s = sqrt(n) - (sqrt(n) - 1) * config.H_sparsity;
%     for k = 1 : num_basis_elems
%         H_norm = norm(H(k, :));
%         H(k, :) = H(k, :) / H_norm;
%         H(k, :) = (projfunc(H(k, :)', L1s, 1, 1))';
%         H(k, :) = H(k, :) * H_norm;
%     end
end

if ~isfield(config, 'maxiter') || config.maxiter <= 0
    config.maxiter = 100;
end

% Maximum tolerance in cost function change per iteration
if ~isfield(config, 'tolerance') || config.tolerance <= 0
    config.tolerance = 1e-3;
end

G0 = G;

S_V_pos = 0.5 * (abs(S' * V) + (S' * V));
S_V_neg = 0.5 * (abs(S' * V) - (S' * V));
S_S_pos = 0.5 * (abs(S' * S) + (S' * S));
S_S_neg = 0.5 * (abs(S' * S) - (S' * S));
identity_mat = eye(n);
W = zeros(m, num_basis_elems, num_frames);
for t = 1 : num_frames
    W(:, :, t) = S * G(:, :, t);
end

cost = zeros(config.maxiter+1, 1);
V_hat = ReconstructFromDecomposition(W, H);
cost(1) = 0.5 * sum(sum((V - V_hat).^2));

stepsizeG = ones(num_frames, 1);
stepsizeH = 1;

for iter = 1 : config.maxiter
    F = zeros(num_points, n);
    for t = 1 : num_frames
        F = F + G0(:, :, t) * [zeros(num_basis_elems, t-1) H(:, 1:n-t+1)];
    end
        
    % Update convex combination tensor
    if ~config.G_fixed
        norms = zeros(num_basis_elems, num_frames);
        for t = 1 : num_frames
            H_shifted = [zeros(num_basis_elems, t-1) H(:, 1:n-t+1)];
            
            % Hoyer's sparsity constraint
%             if config.G_sparsity > 0
%                 % Gradient for H
%                 dG = (S_V_neg + S_S_pos * F) * H_shifted' - (S_V_pos + S_S_neg * F) * H_shifted';
%                 W_current = W;
%                 V_hat = ReconstructFromDecomposition(W_current, H);
%                 begobj = 0.5 * sum(sum((V - V_hat).^2));
% 
%                 % Make sure we decrease the objective!
%                 while 1
%                     % Take step in direction of negative gradient, and project
%                     Gnew = G0(:, :, t) - stepsizeG(t) * dG;
%                     for k = 1 : num_basis_elems
%                         Gnew(:, k) = projfunc(Gnew(:, k), 1, L2s, 1);
%                     end
% 
%                     W_current(:, :, t) = S * Gnew;
% 
%                     % Calculate new objective
%                     V_hat = ReconstructFromDecomposition(W_current, H);
%                     newobj = 0.5 * sum(sum((V - V_hat).^2));
% 
%                     % If the objective decreased, we can continue...
%                     if newobj <= begobj
%                         break;
%                     end
% 
%                     % ...else decrease stepsize and try again
%                     stepsizeG(t) = stepsizeG(t) / 2;
%                     if stepsizeG(t) < 1e-200
%                         fprintf('Algorithm converged.\n');
%                         cost = cost(1 : iter);  % trim
%                         return; 
%                     end
%                 end
% 
%                 % Slightly increase the stepsize
%                 stepsizeG(t) = 1.2 * stepsizeG(t);
%                 G(:, :, t) = Gnew;
%             else
                G(:, :, t) = G0(:, :, t) .* (((S_V_pos + S_S_neg * F) * H_shifted') ./ ((S_V_neg + S_S_pos * F) * H_shifted' + config.G_sparsity));
                norms(:, t) = sum(G(:, :, t), 1)';
                G(:, :, t) = G(:, :, t) * diag(1 ./ sum(G(:, :, t), 1));
%             end
            F = max(F + (G(:, :, t) - G0(:, :, t)) * H_shifted, 0);
            W(:, :, t) = S * G(:, :, t);
        end
%         H = num_frames * diag(1 ./ sum((1 ./ norms), 2)) * H;
    end

    % Update encoding matrix
    if ~config.H_fixed
        F = zeros(num_points, n);
        for t = 1 : num_frames
            F = F + G(:, :, t) * [zeros(num_basis_elems, t-1) H(:, 1:n-t+1)];
        end
        negative_grad = zeros(num_basis_elems, n);
        positive_grad = zeros(num_basis_elems, n);
        for t = 1 : num_frames
            identity_shifted = [identity_mat(:, t:n) zeros(n, t-1)];
            F_shifted = [F(:, t:n) zeros(num_points, t-1)];
            negative_grad = negative_grad + G(:, :, t)' * (S_V_pos * identity_shifted + S_S_neg * F_shifted);
            positive_grad = positive_grad + G(:, :, t)' * (S_V_neg * identity_shifted + S_S_pos * F_shifted);
        end
        % Hoyer's sparsity constraint
%         if config.H_sparsity > 0
%             % Gradient for H
%             dH = positive_grad - negative_grad;
%             begobj = cost(iter);
% 
%             % Make sure we decrease the objective!
%             while 1
%                 % Take step in direction of negative gradient, and project
%                 Hnew = H - stepsizeH * dH;
%                 for k = 1 : num_basis_elems
%                     H_norm = norm(Hnew(k, :));
%                     Hnew(k, :) = Hnew(k, :) / H_norm;
%                     Hnew(k, :) = (projfunc(Hnew(k, :)', L1s, 1, 1))';
%                     Hnew(k, :) = Hnew(k, :) * H_norm;
%                 end
% 
%                 % Calculate new objective
%                 V_hat = ReconstructFromDecomposition(W, Hnew);
%                 newobj = 0.5 * sum(sum((V - V_hat).^2));
% 
%                 % If the objective decreased, we can continue...
%                 if newobj <= begobj
%                     break;
%                 end
% 
%                 % ...else decrease stepsize and try again
%                 stepsizeH = stepsizeH / 2;
%                 if stepsizeH < 1e-200
%                     fprintf('Algorithm converged.\n');
%                     cost = cost(1 : iter);  % trim
%                     return; 
%                 end
%             end
% 
%             % Slightly increase the stepsize
%             stepsizeH = 1.2 * stepsizeH;
%             H = Hnew;
%         else
            H = H .* (negative_grad ./ (positive_grad + config.H_sparsity));
%         end
    end

    % Calculate cost for this iteration
    V_hat = ReconstructFromDecomposition(W, H);
    cost(iter+1) = 0.5 * sum(sum((V - V_hat).^2));
    
    % Stop iterations if change in cost function less than the tolerance
    if iter > 1 && cost(iter+1) < cost(iter) && cost(iter) - cost(iter+1) < config.tolerance
        cost = cost(1 : iter+1);  % trim vector
        break;
    end
    
    G0 = G;
end
